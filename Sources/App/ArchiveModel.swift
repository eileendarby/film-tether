import SwiftUI
import Archive
import Scan
import os

private let archiveLog = Logger(subsystem: "co.wonders.filmtether", category: "Archive")

/// The tray's state: the archive connection, the show and inventory row
/// being worked on, and the queue of scans on their way up.
///
/// Kept apart from `AppModel`, which is about the camera. The two meet in one
/// place: `AppModel` says when a capture has landed on disk, and this decides
/// which asset it belongs to and queues it.
///
/// What survives a relaunch: the refresh token (so nobody types an emailed
/// code per session), the active show, the hot row with its position, and
/// the queue — an interrupted send resumes from the blocks the server still
/// lacks rather than starting over.
@MainActor
final class ArchiveModel: ObservableObject {
    enum AuthState: Equatable { case signedOut, codeSent, signedIn }
    enum Tab: Hashable { case scan, queue }

    private struct PersistedState: Codable {
        var showID: String?
        var run: ScanRun?
        var jobs: [UploadJob]
    }

    private enum Key {
        static let baseURL = "archiveBaseURL"
        static let login = "archiveLogin"
        static let device = "archiveDevice"
    }

    // MARK: - Archive API

    @Published var baseURLText: String { didSet { defaults.set(baseURLText, forKey: Key.baseURL) } }
    @Published var login: String { didSet { defaults.set(login, forKey: Key.login) } }
    @Published var device: String { didSet { defaults.set(device, forKey: Key.device) } }
    /// Never stored. The refresh token stands in for it after sign-in.
    @Published var password = ""
    @Published var code = ""
    @Published private(set) var auth: AuthState = .signedOut
    @Published private(set) var isBusy = false
    @Published var tab: Tab = .scan
    @Published private(set) var errorMessage: String?
    /// Transient confirmation, cleared after a few seconds.
    @Published private(set) var status: String?

    // MARK: - Active show

    @Published var showQuery = "" { didSet { scheduleSearch() } }
    @Published private(set) var showResults: [ArchiveShow] = []
    @Published private(set) var isSearching = false
    /// A search for the current query has come back (so "nothing found" is
    /// a fact, not a search that hasn't run yet).
    @Published private(set) var searchDone = false
    @Published private(set) var currentShow: ArchiveShow?
    @Published private(set) var isCreatingShow = false
    @Published var createCode = ""
    @Published var createName = ""

    // MARK: - Inventory and the add-assets form

    @Published private(set) var inventory: ArchiveInventory?
    @Published private(set) var isLoadingInventory = false
    @Published var formType = "N"
    @Published var formFormatID: Int
    @Published var formRoll = ""
    @Published var formFirst = ""
    @Published var formLast = ""

    // MARK: - Run and queue

    @Published private(set) var run: ScanRun?
    @Published var setNumberText = ""
    @Published private(set) var jobs: [UploadJob] = []

    private var client: ArchiveClient?
    private var engine: UploadEngine?
    private var session: Int?
    private let defaults = UserDefaults.standard
    private let tokenStore = TokenStore(directory: TokenStore.defaultDirectory)
    private let stateURL = TokenStore.defaultDirectory.appendingPathComponent("archive-state.json")
    private var searchTask: Task<Void, Never>?
    private var renderPoll: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    /// Jobs read from disk before there was an engine to give them to.
    private var pendingJobs: [UploadJob] = []
    private var persistedShowID: String?

    var isSignedIn: Bool { auth == .signedIn }

    /// The film sizes the archive knows, by its own ids.
    var formats: [FilmSize] { FilmSize.seedCatalog.filter { !$0.isUnknown } }

    /// Asset types come from the server's type table, via the inventory. Until
    /// a show is loaded, the one everybody needs.
    var types: [InventoryType] {
        if let t = inventory?.types, !t.isEmpty { return t }
        return [InventoryType(type: "N", name: "Negative", total: 0, ranges: [])]
    }

    var activeJobCount: Int { jobs.filter { $0.isActive }.count }
    var failedJobCount: Int { jobs.filter { if case .failed = $0.state { return true } else { return false } }.count }

    init() {
        baseURLText = defaults.string(forKey: Key.baseURL) ?? ""
        login = defaults.string(forKey: Key.login) ?? ""
        device = defaults.string(forKey: Key.device) ?? (Host.current().localizedName ?? "Film Tether")
        formFormatID = AppSettings.shared.expectedFilmSize?.id ?? 2
        restoreState()
        if let creds = tokenStore.load(), let url = try? ArchiveClient.parseBaseURL(creds.baseURL) {
            baseURLText = creds.baseURL
            login = creds.login
            device = creds.device
            session = creds.session
            connect(url: url, refreshToken: creds.refreshToken)
            auth = .signedIn
            if let id = persistedShowID {
                Task { await reloadShow(id: id) }
            }
        }
    }

    // MARK: - Archive API

    private func connect(url: URL, refreshToken: String?) {
        let c = ArchiveClient(baseURL: url, refreshToken: refreshToken)
        client = c
        let e = UploadEngine(client: c)
        engine = e
        let saved = pendingJobs
        pendingJobs = []
        Task {
            await e.setListener { [weak self] jobs in
                Task { @MainActor in self?.jobsChanged(jobs) }
            }
            await e.load(saved)
        }
    }

    /// Step one of signing in: the server emails a one-time code.
    func requestCode() async {
        let url: URL
        do { url = try ArchiveClient.parseBaseURL(baseURLText) } catch { report(error); return }
        if client == nil || client?.baseURL.absoluteString != ArchiveClient(baseURL: url).baseURL.absoluteString {
            connect(url: url, refreshToken: nil)
        }
        guard let client, !login.isEmpty, !password.isEmpty else {
            errorMessage = "Login and password are needed to request a code"
            return
        }
        await busy {
            let r = try await client.requestCode(login: login, password: password)
            auth = .codeSent
            flash(r.sent ? "Code sent — check your email; it's good for \(r.expiresIn / 60) minutes"
                         : "The server did not send a code")
        }
    }

    /// Step two: exchange login, password and the code for tokens.
    func signIn() async {
        guard let client else { return }
        let deviceName = device.trimmingCharacters(in: .whitespaces).isEmpty ? "Film Tether" : device
        await busy {
            let r = try await client.login(login: login, password: password,
                                           code: code.trimmingCharacters(in: .whitespaces), device: deviceName)
            session = r.session
            try tokenStore.save(ArchiveCredentials(baseURL: client.baseURL.absoluteString, login: login,
                                                   device: deviceName, refreshToken: r.refreshToken,
                                                   session: r.session))
            password = ""
            code = ""
            auth = .signedIn
            flash("Signed in as \(login)")
            await engine?.resume()
            if currentShow == nil, let id = persistedShowID { await reloadShow(id: id) }
        }
    }

    /// Forget the device on both sides. The queue and run are kept: signing
    /// back in resumes them.
    func signOut() async {
        if let client, let session {
            try? await client.revoke(session: session)
            await client.signOut()
        }
        tokenStore.clear()
        self.session = nil
        auth = .signedOut
        showResults = []
        flash("Signed out")
    }

    func cancelCode() {
        auth = .signedOut
        code = ""
    }

    // MARK: - Active show

    private func scheduleSearch() {
        searchTask?.cancel()
        searchDone = false
        let q = showQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, isSignedIn else {
            showResults = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.search(q)
        }
    }

    /// What the search actually asks the server for: a show code in any
    /// loose form is expanded to its id (`T316` → `T00316`), so the code
    /// matches exactly; anything else is free text, which the server runs
    /// across every field, notes included.
    static func searchTerm(for text: String) -> String {
        ShowCode.parse(text)?.id ?? text
    }

    private func search(_ q: String) async {
        guard let client else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let page = try await client.searchShows(query: Self.searchTerm(for: q), perpage: 25)
            guard !Task.isCancelled else { return }
            showResults = page.shows
            searchDone = true
        } catch {
            report(error)
        }
    }

    /// Nothing was found for the current query, and it's worth offering to
    /// create a show from it.
    var nothingFound: Bool {
        searchDone && !isSearching && showResults.isEmpty
            && showQuery.trimmingCharacters(in: .whitespaces).count >= 2
    }

    func select(show: ArchiveShow) async {
        currentShow = show
        showResults = []
        showQuery = ""
        isCreatingShow = false
        inventory = nil
        persistState()
        await loadInventory()
    }

    func clearShow() {
        currentShow = nil
        inventory = nil
        persistState()
    }

    /// Turn the search into a creation. What was typed becomes the name —
    /// unless it was a show code, in which case it becomes the code.
    func beginCreateShow() {
        let typed = showQuery.trimmingCharacters(in: .whitespaces)
        if let parsed = ShowCode.parse(typed) {
            createCode = parsed.id
            createName = ""
        } else {
            createCode = ""
            createName = typed
        }
        isCreatingShow = true
    }

    func cancelCreateShow() {
        isCreatingShow = false
    }

    var createCodeIsValid: Bool { ShowCode.parse(createCode) != nil }

    /// Make the show, with an empty inventory, and start working on it.
    func finishCreateShow() async {
        guard let client, let parsed = ShowCode.parse(createCode) else {
            errorMessage = "A show code is a letter and up to five digits, like T316"
            return
        }
        await busy {
            let created = try await client.createShow(category: parsed.category, number: parsed.number,
                                                      name: createName)
            flash("Created \(created.id)")
            createCode = ""
            createName = ""
            await select(show: created)
        }
    }

    private func reloadShow(id: String) async {
        guard let client else { return }
        do {
            let s = try await client.show(id: id)
            currentShow = s
            await loadInventory()
        } catch {
            archiveLog.error("reload show \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Show inventory

    func loadInventory() async {
        guard let client, let show = currentShow else { return }
        isLoadingInventory = true
        defer { isLoadingInventory = false }
        do {
            inventory = try await client.inventory(show: show.id)
            if !types.contains(where: { $0.type == formType }), let first = types.first {
                formType = first.type
            }
        } catch {
            report(error)
        }
    }

    /// The row's parameters, as the add-assets form would hold them.
    private struct RowParameters {
        var type: String
        var roll: String
        var range: NumberRange
        var format: Int
    }

    private func parameters(of type: InventoryType, _ range: InventoryRange) -> RowParameters? {
        guard let r = NumberRange.parse(range.range) else { return nil }
        let format = formats.first { $0.name == range.format }?.id ?? formFormatID
        return RowParameters(type: type.type, roll: (range.roll ?? "").uppercased(), range: r, format: format)
    }

    /// Clicking an inventory row makes it hot: every capture goes to it,
    /// from its first frame. Everything in it is registered already, so the
    /// asset ids are looked up, not created.
    func start(type: InventoryType, range: InventoryRange) async {
        guard let p = parameters(of: type, range) else {
            errorMessage = "Can't step through \(range.range)"
            return
        }
        await busy {
            let ids = try await resolveAssets(p)
            makeHot(p, assetIDs: ids)
            flash("Scanning \(range.range) from \(NumberRange.pad(p.range.firstLabel))")
        }
    }

    var formRange: NumberRange? {
        let first = formFirst.trimmingCharacters(in: .whitespaces)
        let last = formLast.trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty else { return nil }
        return NumberRange.parse(last.isEmpty ? first : "\(first)-\(last)")
    }

    private var formParameters: RowParameters? {
        guard let range = formRange else {
            errorMessage = "Give a first and last number, like 1 and 120, or 12A and 12C"
            return nil
        }
        let roll = formRoll.trimmingCharacters(in: .whitespaces).uppercased()
        guard roll.isEmpty || (roll.count == 1 && roll.first!.isLetter) else {
            errorMessage = "The roll is a single letter, or blank"
            return nil
        }
        return RowParameters(type: formType, roll: roll, range: range, format: formFormatID)
    }

    /// Register the form's assets with the archive so they appear in the
    /// inventory. Only that: clicking the row is what starts scanning it.
    /// Assets that are registered already are simply adopted, so adding a
    /// row that exists is harmless and adds nothing twice.
    func addAssets() async {
        guard let p = formParameters else { return }
        await busy {
            let ids = try await resolveAssets(p)
            formFirst = ""
            formLast = ""
            await loadInventory()
            flash("Added \(ids.count) asset\(ids.count == 1 ? "" : "s"): \(p.range.description)")
        }
    }

    /// Every label in the range ends up with an asset id from the server —
    /// registered now, or adopted if it was registered before. None are
    /// composed here.
    private func resolveAssets(_ p: RowParameters) async throws -> [String: String] {
        guard let client, let show = currentShow else { throw ArchiveError.unauthenticated }
        let labels = (0..<p.range.count).map { p.range.label(at: $0) }
        var byLabel: [String: String] = [:]
        do {
            let batch = try await client.registerAssets(show: show.id, type: p.type, roll: p.roll,
                                                        first: p.range.firstLabel, last: p.range.lastLabel,
                                                        format: p.format)
            for a in batch.assets { byLabel[NumberRange.normalize(a.number)] = a.assetid }
        } catch let e as ArchiveError where e.alreadyRegisteredAssetIDs != nil {
            // Some or all of the run is catalogued already. Take what's
            // there and register only the gaps, one at a time.
            let existing = try await client.allAssets(show: show.id, type: p.type)
            let wanted = Set(labels)
            for a in existing where (a.roll ?? "").uppercased() == p.roll {
                let label = NumberRange.normalize(a.number)
                if wanted.contains(label) { byLabel[label] = a.assetid }
            }
            for label in labels where byLabel[label] == nil {
                let b = try await client.registerAsset(show: show.id, type: p.type, roll: p.roll,
                                                       number: label, format: p.format)
                if let a = b.assets.first { byLabel[label] = a.assetid }
            }
        }
        let missing = labels.filter { byLabel[$0] == nil }
        guard missing.isEmpty else {
            throw ArchiveError.http(status: 0, message: "The server gave no asset for \(missing.map(NumberRange.pad).joined(separator: ", "))")
        }
        return byLabel
    }

    private func makeHot(_ p: RowParameters, assetIDs: [String: String]) {
        guard let show = currentShow else { return }
        let typeName = types.first { $0.type == p.type }?.displayName
        let formatName = formats.first { $0.id == p.format }?.name
        run = ScanRun(show: show.id, showName: show.name, type: p.type, typeName: typeName,
                      roll: p.roll.isEmpty ? nil : p.roll, format: p.format, formatName: formatName,
                      range: p.range, assetIDs: assetIDs)
        setNumberText = ""
        persistState()
    }

    // MARK: - Scanning

    func skipNumber() {
        guard var r = run, let label = r.currentPadded else { return }
        r.skip()
        run = r
        persistState()
        flash("Skipped \(label)")
    }

    func stepBack() {
        guard var r = run else { return }
        r.back()
        run = r
        persistState()
    }

    /// Jump to whatever was typed: a number, padded or not, a suffixed
    /// label, or a bare letter in a suffix run.
    func applySetNumber() {
        guard var r = run else { return }
        let text = setNumberText.trimmingCharacters(in: .whitespaces)
        guard r.jump(toLabel: text) else {
            errorMessage = "\(text) isn't in \(r.range.description)"
            return
        }
        run = r
        setNumberText = ""
        persistState()
    }

    /// Done with this row for now. Not "complete": the row stays in the
    /// inventory and can be made hot again later.
    func finish() {
        run = nil
        persistState()
    }

    /// A capture has been written. If a row is hot, it belongs to the
    /// current frame: the RAW goes to its `00` version and moves the run on;
    /// a JPEG alongside it goes to a `01` version, registered on the spot.
    func captureCompleted(files: [URL], primary: URL) {
        guard var r = run, let label = r.currentLabel, let assetID = r.currentAssetID else { return }
        r.markScanned()
        run = r
        enqueue(UploadJob(assetID: assetID, fileURL: primary, show: r.show, label: label))
        for companion in files where companion != primary {
            Task { await sendSecondary(companion, label: label, run: r) }
        }
        persistState()
        if r.isFinished {
            flash("Row finished: \(r.scanned.count) scanned, \(r.skipped.count) skipped")
        }
    }

    private func enqueue(_ job: UploadJob) {
        if let engine {
            Task { await engine.enqueue(job) }
        } else {
            pendingJobs.append(job)
            jobs.append(job)
        }
    }

    /// The JPEG of a RAW+JPEG capture is version `01` of the same asset. The
    /// version is registered the first time a label produces one; a redo
    /// finds it remembered on the run, or named in the server's 409.
    private func sendSecondary(_ file: URL, label: String, run r: ScanRun) async {
        guard let client else { return }
        var id = r.secondaryAssetIDs[label]
        if id == nil {
            do {
                let b = try await client.registerAsset(show: r.show, type: r.type, roll: r.roll,
                                                       number: label, format: r.format, version: 1)
                id = b.assets.first?.assetid
            } catch let e as ArchiveError {
                if let existing = e.alreadyRegisteredAssetIDs?.first {
                    id = existing
                } else {
                    report(e)
                    return
                }
            } catch {
                report(error)
                return
            }
            if let id, var current = run, current.show == r.show, current.range == r.range {
                current.secondaryAssetIDs[label] = id
                run = current
                persistState()
            }
        }
        guard let id else { return }
        enqueue(UploadJob(assetID: id, fileURL: file, show: r.show, label: label))
    }

    // MARK: - Queue

    func retry(_ job: UploadJob) {
        Task { await engine?.retry(job.id) }
    }

    func remove(_ job: UploadJob) {
        Task { await engine?.remove(job.id) }
    }

    func clearFinished() {
        Task { await engine?.clearDone() }
    }

    private func jobsChanged(_ new: [UploadJob]) {
        jobs = new
        persistState()
        if new.contains(where: { if case .failed(let why) = $0.state { return why.hasPrefix("Signed out") } else { return false } }),
           auth == .signedIn {
            auth = .signedOut
            errorMessage = "The archive refused this device's token — sign in again"
        }
        ensureRenderPolling()
    }

    /// `completed` is not `rendered`: derivatives are built by a cron job
    /// afterwards. While anything is sent-but-not-filed, ask every 15 s.
    private func ensureRenderPolling() {
        let needed = jobs.contains { $0.state == .complete }
        if needed, renderPoll == nil {
            renderPoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard let self, let engine = await self.engine else { return }
                    await engine.pollRendered()
                    if await !self.jobs.contains(where: { $0.state == .complete }) { break }
                }
                await MainActor.run { self?.renderPoll = nil }
            }
        }
    }

    // MARK: - Persistence

    private func persistState() {
        let state = PersistedState(showID: currentShow?.id, run: run, jobs: jobs)
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            archiveLog.error("persist: \(String(describing: error), privacy: .public)")
        }
    }

    private func restoreState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        run = state.run
        pendingJobs = state.jobs
        jobs = state.jobs
        persistedShowID = state.showID
    }

    // MARK: - Feedback

    private func busy(_ work: () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        if let e = error as? ArchiveError, e == .unauthenticated {
            auth = .signedOut
            errorMessage = "Not signed in — the archive refused this device's token"
        } else {
            errorMessage = (error as? ArchiveError)?.errorDescription ?? error.localizedDescription
        }
        archiveLog.error("\(self.errorMessage ?? "", privacy: .public)")
    }

    func dismissError() {
        errorMessage = nil
    }

    private func flash(_ text: String) {
        status = text
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }
}
