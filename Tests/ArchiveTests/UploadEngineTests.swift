import XCTest
@testable import Archive

/// A stand-in for the server's transfer table: registers uploads, checks
/// each block's length, marks it received, and reports `complete` on the
/// block that leaves nothing outstanding.
final class FakeUploadServer {
    struct Transfer {
        var id: Int
        var assetid: String
        var bytes: Int
        var chunkSize: Int
        var chunks: Int
        var outstanding: Set<Int>
        var rendered = false
    }

    let lock = NSLock()
    var transfers: [Int: Transfer] = [:]
    var nextID = 1
    /// Fail the first PUT of these blocks with a 422, once, to prove resends.
    var damageOnce: Set<Int> = []
    var putCount = 0

    func markRendered(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        transfers[id]?.rendered = true
    }

    func handle(_ req: URLRequest, _ body: Data?) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = Mock.path(req)
        if path == "/auth/refresh" {
            return (200, Mock.json(#"{ "access_token": "A", "expires_in": 900 }"#))
        }
        if path == "/uploads", req.httpMethod == "POST" {
            let o = Mock.jsonObject(body)
            let bytes = o["bytes"] as! Int
            let chunkSize = o["chunk_size"] as! Int
            let chunks = (o["chunks"] as! [String]).count
            XCTAssertEqual(chunks, (bytes + chunkSize - 1) / chunkSize, "checksum count must match the block count")
            XCTAssertEqual((o["sha256"] as! String).count, 64)
            let t = Transfer(id: nextID, assetid: o["assetid"] as! String, bytes: bytes, chunkSize: chunkSize,
                             chunks: chunks, outstanding: Set(0..<chunks))
            transfers[nextID] = t
            nextID += 1
            return (201, describe(t))
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "uploads", let id = Int(parts[1]), var t = transfers[id] {
            if parts.count == 4, parts[2] == "chunks", let n = Int(parts[3]), req.httpMethod == "PUT" {
                putCount += 1
                XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
                let expected = n == t.chunks - 1 ? t.bytes - n * t.chunkSize : t.chunkSize
                guard (body?.count ?? 0) == expected else {
                    return (400, Mock.json(#"{ "error": "Block \#(n) should be \#(expected) bytes, received \#(body?.count ?? 0)" }"#))
                }
                if damageOnce.contains(n) {
                    damageOnce.remove(n)
                    return (422, Mock.json(#"{ "error": "Block \#(n) did not survive the journey; send it again" }"#))
                }
                t.outstanding.remove(n)
                transfers[id] = t
                return (200, describe(t))
            }
            if parts.count == 2, req.httpMethod == "GET" {
                return (200, describe(t))
            }
        }
        return (404, Mock.json(#"{ "error": "No such transfer" }"#))
    }

    private func describe(_ t: Transfer) -> Data {
        let complete = t.outstanding.isEmpty
        // Cap the listed blocks at 50 like the real server, with the true count alongside.
        let listed = Array(t.outstanding.sorted().prefix(50))
        let json = """
        { "id": \(t.id), "assetid": "\(t.assetid)", "state": "\(complete ? "complete" : "sending")",
          "bytes": \(t.bytes), "chunk_size": \(t.chunkSize), "chunks": \(t.chunks),
          "received": \(t.chunks - t.outstanding.count), "percent": 0,
          "outstanding": \(listed), "outstanding_total": \(t.outstanding.count),
          "completed": \(complete ? "1789368134" : "null"), "rendered": \(t.rendered ? "1789368200" : "null"), "render_error": null }
        """
        return Mock.json(json)
    }
}

final class UploadEngineTests: XCTestCase {
    private func tempFile(bytes: Int) throws -> URL {
        var data = Data(count: bytes)
        for i in 0..<bytes { data[i] = UInt8(i & 0xff) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).cr3")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func waitForSettled(_ engine: UploadEngine, timeout: TimeInterval = 10) async -> [UploadJob] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let jobs = await engine.snapshot()
            if !jobs.contains(where: { $0.isActive }) { return jobs }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await engine.snapshot()
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testSendsEveryBlockAndCompletes() async throws {
        let server = FakeUploadServer()
        MockURLProtocol.handler = server.handle
        let engine = UploadEngine(client: Mock.client(), chunkSize: 1024)
        let seen = Observed()
        await engine.setListener { jobs in seen.record(jobs) }

        let url = try tempFile(bytes: 3000)
        await engine.enqueue(UploadJob(assetID: "T00316_NA0001_00", fileURL: url, show: "T00316", label: "1"))
        let jobs = await waitForSettled(engine)

        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].state, .complete)
        XCTAssertEqual(jobs[0].uploadID, 1)
        XCTAssertEqual(jobs[0].bytes, 3000)
        XCTAssertEqual(server.putCount, 3)
        XCTAssertTrue(server.transfers[1]!.outstanding.isEmpty)
        // Progress was reported block by block.
        let states = seen.states
        XCTAssertTrue(states.contains(.hashing))
        XCTAssertTrue(states.contains(.sending(sent: 1, total: 3)))
        XCTAssertTrue(states.contains(.sending(sent: 2, total: 3)))
    }

    func testDamagedBlockIsResentNotRestarted() async throws {
        let server = FakeUploadServer()
        server.damageOnce = [1]
        MockURLProtocol.handler = server.handle
        let engine = UploadEngine(client: Mock.client(), chunkSize: 1024)
        let url = try tempFile(bytes: 3000)
        await engine.enqueue(UploadJob(assetID: "T00316_NA0001_00", fileURL: url, show: "T00316", label: "1"))
        let jobs = await waitForSettled(engine)
        XCTAssertEqual(jobs[0].state, .complete)
        XCTAssertEqual(server.putCount, 4, "three blocks plus one resend")
        XCTAssertEqual(server.transfers.count, 1, "no second transfer was registered")
    }

    func testResumesAnInterruptedTransfer() async throws {
        let server = FakeUploadServer()
        MockURLProtocol.handler = server.handle
        let url = try tempFile(bytes: 3000)
        // A transfer the previous launch registered and half-sent.
        server.transfers[1] = FakeUploadServer.Transfer(id: 1, assetid: "T00316_NA0001_00", bytes: 3000,
                                                        chunkSize: 1024, chunks: 3, outstanding: [2])
        server.nextID = 2
        var job = UploadJob(assetID: "T00316_NA0001_00", fileURL: url, show: "T00316", label: "1")
        job.uploadID = 1
        job.state = .sending(sent: 2, total: 3)

        let engine = UploadEngine(client: Mock.client(), chunkSize: 1024)
        await engine.load([job])
        let jobs = await waitForSettled(engine)
        XCTAssertEqual(jobs[0].state, .complete)
        XCTAssertEqual(server.putCount, 1, "only the outstanding block was sent")
        XCTAssertEqual(server.transfers.count, 1, "resumed, not re-registered")
    }

    func testJobsRunInOrderAndAFailureDoesNotBlockTheNext() async throws {
        let server = FakeUploadServer()
        MockURLProtocol.handler = server.handle
        let engine = UploadEngine(client: Mock.client(), chunkSize: 1024)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).cr3")
        let good = try tempFile(bytes: 2000)
        await engine.enqueue(UploadJob(assetID: "T00316_NA0001_00", fileURL: missing, show: "T00316", label: "1"))
        await engine.enqueue(UploadJob(assetID: "T00316_NA0002_00", fileURL: good, show: "T00316", label: "2"))
        let jobs = await waitForSettled(engine, timeout: 30)
        guard case .failed = jobs[0].state else { return XCTFail("first should fail: \(jobs[0].state)") }
        XCTAssertEqual(jobs[1].state, .complete)
        XCTAssertEqual(server.transfers[1]?.assetid, "T00316_NA0002_00")
    }

    func testSignedOutPausesTheQueue() async throws {
        MockURLProtocol.handler = { _, _ in (401, Mock.json(#"{ "error": "Invalid credentials" }"#)) }
        let engine = UploadEngine(client: Mock.client(), chunkSize: 1024)
        let a = try tempFile(bytes: 100)
        let b = try tempFile(bytes: 100)
        await engine.enqueue(UploadJob(assetID: "x", fileURL: a, show: "T", label: "1"))
        await engine.enqueue(UploadJob(assetID: "y", fileURL: b, show: "T", label: "2"))
        let jobs = await waitForSettled(engine)
        XCTAssertEqual(jobs[0].state, .failed("Signed out — sign in and retry"))
        XCTAssertEqual(jobs[1].state, .queued, "the rest wait rather than each failing in turn")
    }

    func testPollRendered() async throws {
        let server = FakeUploadServer()
        MockURLProtocol.handler = server.handle
        let engine = UploadEngine(client: Mock.client(), chunkSize: 1024)
        let url = try tempFile(bytes: 1500)
        await engine.enqueue(UploadJob(assetID: "T00316_NA0001_00", fileURL: url, show: "T00316", label: "1"))
        _ = await waitForSettled(engine)
        await engine.pollRendered()
        var jobs = await engine.snapshot()
        XCTAssertEqual(jobs[0].state, .complete, "not rendered yet")
        server.markRendered(1)
        await engine.pollRendered()
        jobs = await engine.snapshot()
        XCTAssertEqual(jobs[0].state, .rendered)
    }
}

/// Collects listener snapshots across threads.
final class Observed: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[UploadJob]] = []
    func record(_ jobs: [UploadJob]) { lock.lock(); snapshots.append(jobs); lock.unlock() }
    var states: [UploadJob.State] { lock.lock(); defer { lock.unlock() }; return snapshots.compactMap { $0.first?.state } }
}
