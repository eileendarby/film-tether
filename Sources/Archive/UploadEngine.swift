import Foundation

/// One scan on its way to the archive.
public struct UploadJob: Codable, Identifiable, Equatable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        case queued
        case hashing
        case sending(sent: Int, total: Int)
        /// Filed on the server; derivatives may not exist yet.
        case complete
        /// Thumbnail, gallery and subscriber sizes are on disk.
        case rendered
        case failed(String)
    }

    public var id: UUID
    public var assetID: String
    public var fileURL: URL
    public var show: String
    /// The frame's label in the run ("12", "12A"), for display.
    public var label: String
    public var state: State
    /// The server's transfer id, kept so an interrupted send resumes rather
    /// than restarts.
    public var uploadID: Int?
    public var bytes: Int?
    public var created: Date
    public var completed: Date?
    public var renderError: String?

    public init(assetID: String, fileURL: URL, show: String, label: String) {
        id = UUID()
        self.assetID = assetID
        self.fileURL = fileURL
        self.show = show
        self.label = label
        state = .queued
        created = Date()
    }

    /// Still to do, or in progress.
    public var isActive: Bool {
        switch state {
        case .queued, .hashing, .sending: return true
        case .complete, .rendered, .failed: return false
        }
    }

    public var isDone: Bool {
        switch state {
        case .complete, .rendered: return true
        default: return false
        }
    }

    /// 0…1 of the bytes sent.
    public var progress: Double {
        switch state {
        case .queued, .hashing: return 0
        case .sending(let sent, let total): return total > 0 ? Double(sent) / Double(total) : 0
        case .complete, .rendered: return 1
        case .failed: return 0
        }
    }

    public var stateLabel: String {
        switch state {
        case .queued: return "Waiting"
        case .hashing: return "Reading"
        case .sending(let sent, let total): return "Sending \(sent)/\(total)"
        case .complete: return "Sent"
        case .rendered: return "Filed"
        case .failed(let why): return "Failed: \(why)"
        }
    }
}

/// Sends scans to the archive, one at a time, in the order they were queued.
///
/// A transfer is registered first (the server writes down every block it
/// will consist of), then the blocks go up. Because the server remembers what
/// it has, a failure part-way is resumed by asking which blocks are still
/// outstanding and sending those — never by starting over. Every state change
/// is reported to the listener with a snapshot of the whole queue.
public actor UploadEngine {
    public typealias Listener = @Sendable ([UploadJob]) -> Void

    private let client: ArchiveClient
    private let chunkSize: Int
    private var jobs: [UploadJob] = []
    private var listener: Listener?
    private var worker: Task<Void, Never>?
    /// Set when the server refused our credentials. Nothing is attempted
    /// until `resume()` — a revoked device must stop, not loop.
    private var paused = false

    /// Per-block retries for a damaged block (422) or a dropped connection.
    private let blockAttempts = 3
    /// Whole-job retries for network trouble, with a short pause between.
    private let jobAttempts = 3

    public init(client: ArchiveClient, chunkSize: Int = Chunker.defaultChunkSize) {
        self.client = client
        self.chunkSize = chunkSize
    }

    public func setListener(_ l: Listener?) {
        listener = l
    }

    public func snapshot() -> [UploadJob] { jobs }

    /// Restore a queue saved by a previous launch. Anything that was in
    /// flight goes back to waiting, keeping its transfer id so it resumes.
    public func load(_ saved: [UploadJob]) {
        jobs = saved.map { job in
            var j = job
            if j.isActive { j.state = .queued }
            return j
        }
        notify()
        pump()
    }

    public func enqueue(_ job: UploadJob) {
        jobs.append(job)
        notify()
        pump()
    }

    public func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if case .failed = jobs[i].state {
            jobs[i].state = .queued
            notify()
            paused = false
            pump()
        }
    }

    public func remove(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs.remove(at: i)
        notify()
        if let uploadID = job.uploadID, !job.isDone {
            Task { try? await client.abandonUpload(id: uploadID) }
        }
    }

    /// Drop finished entries from the list.
    public func clearDone() {
        jobs.removeAll { $0.isDone }
        notify()
    }

    /// Try again after signing in.
    public func resume() {
        paused = false
        pump()
    }

    /// Ask the server whether derivatives now exist for anything sent.
    public func pollRendered() async {
        for job in jobs where job.state == .complete {
            guard let uploadID = job.uploadID else { continue }
            guard let u = try? await client.upload(id: uploadID) else { continue }
            if u.isRendered {
                update(job.id) { $0.state = .rendered }
            } else if let err = u.renderError, !err.isEmpty {
                update(job.id) { $0.renderError = err }
            }
        }
    }

    // MARK: - Worker

    private func pump() {
        guard worker == nil, !paused else { return }
        guard jobs.contains(where: { $0.state == .queued }) else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !paused, let next = jobs.first(where: { $0.state == .queued }) {
            await process(next.id)
        }
        worker = nil
    }

    private func process(_ id: UUID) async {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await sendOnce(id)
                return
            } catch ArchiveError.unauthenticated {
                update(id) { $0.state = .failed("Signed out — sign in and retry") }
                paused = true
                return
            } catch let e as ArchiveError {
                // Server-side refusals won't change on a retry; only network
                // trouble is worth another go.
                let retryable: Bool
                if case .network = e { retryable = true } else { retryable = false }
                if retryable, attempt < jobAttempts {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                update(id) { $0.state = .failed(e.localizedDescription) }
                return
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
                return
            }
        }
    }

    private func sendOnce(_ id: UUID) async throws {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        update(id) { $0.state = .hashing }

        let file: ChunkedFile
        do {
            file = try Chunker.digest(fileAt: job.fileURL, chunkSize: chunkSize)
        } catch {
            throw ArchiveError.file("Could not read \(job.fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        guard file.bytes > 0 else { throw ArchiveError.http(status: 0, message: "The file is empty") }
        update(id) { $0.bytes = file.bytes }

        // Resume the previous transfer if the server still has it; otherwise
        // register a new one. Registering again for the same asset abandons
        // and replaces an unfinished transfer, so that path is safe too.
        var upload: ArchiveUpload? = nil
        if let previous = job.uploadID, let u = try? await client.upload(id: previous),
           !u.isAbandoned, u.chunks == file.chunkCount, u.bytes == file.bytes {
            upload = u
        }
        if upload == nil {
            upload = try await client.createUpload(assetID: job.assetID, filename: job.fileURL.lastPathComponent, file: file)
        }
        guard var current = upload else { throw ArchiveError.badResponse }
        let total = current.chunks ?? file.chunkCount
        update(id) {
            $0.uploadID = current.id
            $0.state = .sending(sent: total - current.remaining, total: total)
        }

        while !current.isComplete {
            if current.remaining == 0 {
                // Everything was received but the state didn't say complete;
                // re-read rather than spin.
                current = try await client.upload(id: current.id)
                if current.isComplete { break }
                throw ArchiveError.http(status: 0, message: "Transfer stalled with nothing outstanding (state \(current.state))")
            }
            // `outstanding` lists at most 50; send those, then ask again.
            let batch = current.outstanding
            for index in batch {
                let data = try Chunker.readChunk(fileAt: job.fileURL, index: index, chunkSize: chunkSize)
                current = try await putWithRetry(uploadID: current.id, index: index, data: data)
                update(id) { $0.state = .sending(sent: total - current.remaining, total: total) }
                if current.isComplete { break }
            }
            if !current.isComplete, current.remaining > 0 {
                current = try await client.upload(id: current.id)
            }
        }

        update(id) {
            $0.state = .complete
            $0.completed = Date()
        }
    }

    /// A damaged block (422) or a dropped connection is sent again; a wrong
    /// length (400) means our chunking disagrees with the server's and no
    /// retry will fix it.
    private func putWithRetry(uploadID: Int, index: Int, data: Data) async throws -> ArchiveUpload {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await client.putChunk(uploadID: uploadID, index: index, data: data)
            } catch ArchiveError.http(422, let message) where attempt < blockAttempts {
                _ = message
                continue
            } catch ArchiveError.network where attempt < blockAttempts {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout UploadJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        notify()
    }

    private func notify() {
        listener?(jobs)
    }
}
