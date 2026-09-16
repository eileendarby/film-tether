import SwiftUI
import QuickLookThumbnailing
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
    /// Set by Change so the search field takes the cursor when it appears.
    /// Not at launch: focusing it then would swallow the capture hotkey.
    @Published var wantsSearchFocus = false
    @Published var createCode = ""
    @Published var createName = ""

    // MARK: - Inventory and the add-assets form

    @Published private(set) var inventory: ArchiveInventory?
    @Published private(set) var isLoadingInventory = false
    /// Which frames of each type have a scan filed, keyed by type letter and
    /// then "roll|label". Read from the assets' image block, which the
    /// archive fills in when a scan arrives.
    @Published private(set) var scannedFrames: [String: Set<String>] = [:]
    private var scanStatusTask: Task<Void, Never>?
    private var lastDoneCount = 0
    /// Pictures of the hot row's frames, by the RAW's assetid.
    @Published private(set) var thumbnails: [String: Thumbnail] = [:]
    private var thumbnailWork: Set<String> = []
    private var archiveTried: [String: Date] = [:]
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
        // 120mm Rollei, the archive's id 2: most of what gets scanned. Not the
        // auto-crop's expected size, which follows whatever is under the lens.
        formFormatID = 2
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
            // By show code, whatever order the server chose: T00316 before
            // T00317, and the categories together.
            showResults = page.shows.sorted { $0.id < $1.id }
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

    /// Back to the search. A row being scanned is finished first — the same
    /// "done for now" as the Finish button, so nothing is lost and the row
    /// can be made hot again from the inventory later.
    /// A bracketed phrase in a note was clicked: back to the search, with
    /// that phrase as the query. Finishes any row being scanned, as Change
    /// does.
    func searchFromNote(_ term: String) {
        clearShow()
        showQuery = term
    }

    func clearShow() {
        run = nil
        currentShow = nil
        inventory = nil
        isCreatingShow = false
        wantsSearchFocus = true
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
        await loadScanStatus()
    }

    private func loadScanStatus() async {
        guard let client, let show = currentShow, let inv = inventory else { return }
        var result: [String: Set<String>] = [:]
        for type in inv.types where !type.ranges.isEmpty {
            guard let assets = try? await client.allAssets(show: show.id, type: type.type) else { continue }
            result[type.type] = Set(assets.filter(\.hasScan).map { Self.frameKey(roll: $0.roll, label: $0.number) })
        }
        scannedFrames = result
    }

    private static func frameKey(roll: String?, label: String) -> String {
        "\((roll ?? "").uppercased())|\(NumberRange.normalize(label))"
    }

    /// Positions in the run whose frames have a scan filed in the archive.
    func archivedPositions(of run: ScanRun) -> [Int] {
        let filed = scannedFrames[run.type] ?? []
        return (0..<run.range.count).filter {
            filed.contains(Self.frameKey(roll: run.roll, label: run.range.label(at: $0)))
        }
    }

    /// "In archive: 1-4, 7 (5 of 20)", for the Scanning panel.
    func archivedSummary(of run: ScanRun) -> String {
        let p = archivedPositions(of: run)
        if p.isEmpty { return "In archive: none yet" }
        return "In archive: \(run.range.summary(ofPositions: p)) (\(p.count) of \(run.range.count))"
    }

    /// How much of an inventory row is in the archive: frames with a scan
    /// filed, out of the row's frames. Nil for a row that can't be stepped.
    func coverage(of type: InventoryType, _ range: InventoryRange) -> (scanned: Int, total: Int)? {
        guard let r = NumberRange.parse(range.range) else { return nil }
        let filed = scannedFrames[type.type] ?? []
        let n = (0..<r.count).filter { filed.contains(Self.frameKey(roll: range.roll, label: r.label(at: $0))) }.count
        return (n, r.count)
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
            await loadScanStatus()   // so Next lands on the first frame the archive lacks
            makeHot(p, assetIDs: ids)
            if let next = run?.currentPadded {
                flash("Scanning \(range.range) from \(next)")
            } else {
                flash("\(range.range) is all in the archive already")
            }
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
        var r = ScanRun(show: show.id, showName: show.name, type: p.type, typeName: typeName,
                        roll: p.roll.isEmpty ? nil : p.roll, format: p.format, formatName: formatName,
                        range: p.range, assetIDs: assetIDs)
        // Next is the first frame the archive doesn't have yet. If it has
        // them all, the row starts finished; Back or the jump field reopen it.
        let filed = Set(archivedPositions(of: r))
        r.jump(to: (0..<r.range.count).first { !filed.contains($0) } ?? r.range.count)
        run = r
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

    /// The negative under the current number doesn't exist — the strip was
    /// miscounted. Take it out of the row, and out of the archive where this
    /// station is allowed to (deleting needs access level 61; a scanning
    /// station usually isn't, and is told so).
    func removeCurrent() async {
        guard var r = run, let label = r.currentLabel, let padded = r.currentPadded, let assetID = r.currentAssetID else { return }
        var kept: String? = nil
        if let client, let name = ArchiveAsset.pathName(ofAssetID: assetID) {
            var ids = [assetID]
            if let jpeg = r.secondaryAssetIDs[label] { ids.append(jpeg) }
            for id in ids {
                let version = String(id.split(separator: "_").last ?? "00")
                do {
                    try await client.deleteAssetVersion(show: r.show, asset: name, version: version)
                } catch ArchiveError.http(403, _) {
                    kept = "the archive keeps it: deleting needs access level 61"
                } catch {
                    report(error)
                    return
                }
            }
        }
        r.removeCurrent()
        run = r
        persistState()
        flash(kept.map { "Removed \(padded) from this row; \($0)" } ?? "Removed \(padded) from the row and the archive")
        await loadInventory()
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
    func captureCompleted(files: [URL], primary: URL, attributes: CaptureAttributes) {
        guard var r = run, let label = r.currentLabel, let assetID = r.currentAssetID else { return }
        r.markScanned()
        run = r
        // The archive refuses a crop whose format disagrees with the asset's;
        // the row's format is the asset's, so it wins over the crop's guess.
        var attrs = attributes
        attrs.crop?.format = r.format
        let sent = attrs.validated()
        enqueue(UploadJob(assetID: assetID, fileURL: primary, show: r.show, label: label, attributes: sent))
        for companion in files where companion != primary {
            Task { await sendSecondary(companion, label: label, run: r, attributes: sent) }
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
    private func sendSecondary(_ file: URL, label: String, run r: ScanRun, attributes: CaptureAttributes?) async {
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
        enqueue(UploadJob(assetID: id, fileURL: file, show: r.show, label: label, attributes: attributes))
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
        let newlyRendered = new.filter { j in
            j.state == .rendered && !jobs.contains { $0.id == j.id && $0.state == .rendered }
        }
        jobs = new
        persistState()
        if !newlyRendered.isEmpty { upgradeThumbnails(for: newlyRendered) }
        // A send finished: the inventory colours are out of date. Ask again,
        // a moment later so a burst of completions costs one request.
        let done = new.filter { $0.isDone }.count
        if done != lastDoneCount {
            lastDoneCount = done
            scanStatusTask?.cancel()
            scanStatusTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.loadScanStatus()
            }
        }
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

    // MARK: - Thumbnails

    struct Thumbnail: Equatable {
        enum Source: Equatable { case local, archive }
        var image: NSImage
        var source: Source
    }

    struct Frame: Identifiable {
        var label: String
        var assetID: String
        /// Nil until requested and loaded.
        var thumbnail: Thumbnail?
        var id: String { assetID }
    }

    /// The hot row's frames that have a scan — in the archive, or captured
    /// here — in row order, lowest number at the top. Pictures are loaded
    /// as the list is scrolled, not for every frame up front: a 500-frame
    /// row costs nothing until it's looked at.
    func frames(of run: ScanRun) -> [Frame] {
        let filed = scannedFrames[run.type] ?? []
        return (0..<run.range.count).compactMap { i in
            let label = run.range.label(at: i)
            guard !run.isRemoved(label), let id = run.assetID(for: label) else { return nil }
            let available = filed.contains(Self.frameKey(roll: run.roll, label: label))
                || jobs.contains { $0.assetID == id && $0.isDone }
                || localFile(for: id, label: label, show: run.show) != nil
            guard available else { return nil }
            return Frame(label: label, assetID: id, thumbnail: thumbnails[id])
        }
    }

    struct ScannedBlock: Identifiable {
        /// "1-20" or "55", in the row's notation.
        var text: String
        var firstAssetID: String
        var id: String { firstAssetID }
    }

    /// The scanned frames as runs of consecutive numbers — "1-20, 26-35,
    /// 55" — each knowing its first frame, so a click can jump the list there.
    func scannedBlocks(of run: ScanRun) -> [ScannedBlock] {
        let positions = frames(of: run).compactMap { run.range.index(of: $0.label) }.sorted()
        var blocks: [ScannedBlock] = []
        var i = 0
        while i < positions.count {
            var j = i
            while j + 1 < positions.count, positions[j + 1] == positions[j] + 1 { j += 1 }
            let text = run.range.summary(ofPositions: Array(positions[i...j]))
            if let id = run.assetID(for: run.range.label(at: positions[i])) {
                blocks.append(ScannedBlock(text: text, firstAssetID: id))
            }
            i = j + 1
        }
        return blocks
    }

    /// Called when a frame's cell comes into view. The archive's thumbnail
    /// where the scan has been rendered, else one made here from the local
    /// file. A frame the archive has but hasn't rendered yet gets its local
    /// picture and is asked about again after a while.
    func requestThumbnail(for frame: Frame, in run: ScanRun) {
        let id = frame.assetID
        let inArchive = (scannedFrames[run.type] ?? []).contains(Self.frameKey(roll: run.roll, label: frame.label))
            || jobs.contains { $0.assetID == id && $0.state == .rendered }
        let askedRecently = archiveTried[id].map { Date().timeIntervalSince($0) < 30 } ?? false
        let wantArchive = inArchive && thumbnails[id]?.source != .archive && !askedRecently
        let wantLocal = thumbnails[id] == nil
        guard wantArchive || wantLocal, !thumbnailWork.contains(id) else { return }
        thumbnailWork.insert(id)
        let local = localFile(for: id, label: frame.label, show: run.show)
        let show = run.show
        Task { [weak self] in
            await self?.loadThumbnail(assetID: id, show: show, tryArchive: wantArchive, localFile: local)
        }
    }

    /// A send was just filed with derivatives: swap its local picture for
    /// the archive's, if one is showing.
    private func upgradeThumbnails(for rendered: [UploadJob]) {
        guard let run else { return }
        for job in rendered where thumbnails[job.assetID]?.source == .local {
            if let frame = frames(of: run).first(where: { $0.assetID == job.assetID }) {
                archiveTried[job.assetID] = nil
                requestThumbnail(for: frame, in: run)
            }
        }
    }

    /// The file this session captured for a frame, if it's still on disk —
    /// the JPEG when there is one, since it thumbnails faster than the RAW.
    private func localFile(for assetID: String, label: String, show: String) -> URL? {
        let middle = ArchiveAsset.pathName(ofAssetID: assetID)
        let candidates = jobs
            .filter { $0.show == show && $0.label == label && ArchiveAsset.pathName(ofAssetID: $0.assetID) == middle }
            .map(\.fileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return candidates.first { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) } ?? candidates.first
    }

    private func loadThumbnail(assetID: String, show: String, tryArchive: Bool, localFile: URL?) async {
        defer { thumbnailWork.remove(assetID) }
        if tryArchive, let client, let name = ArchiveAsset.pathName(ofAssetID: assetID) {
            archiveTried[assetID] = Date()
            if let data = try? await client.image(show: show, asset: name, kind: "thumbnail"),
               let image = NSImage(data: data) {
                thumbnails[assetID] = Thumbnail(image: image, source: .archive)
                return
            }
        }
        guard thumbnails[assetID] == nil, let file = localFile else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: CGSize(width: 720, height: 720), scale: 2, representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnails[assetID] = Thumbnail(image: rep.nsImage, source: .local)
        }
    }
}
