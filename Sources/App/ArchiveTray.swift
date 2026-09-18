import SwiftUI
import Archive
import Scan

/// The right-hand column: where scans are going, and how they're getting
/// there. Two tabs — Scan (the archive, the active show, its inventory, and
/// either the add-assets form or the scanning controls) and Queue (every
/// send and its progress). Closable from the toolbar or the View menu for
/// anyone scanning to disk only.
///
/// The Scan tab's sections keep their order whatever state things are in:
/// Archive API, Active Show, Show Inventory, then Add Assets *or* Scanning —
/// those two replace each other, and never move above the inventory.
struct ArchiveTray: View {
    @ObservedObject var archive: ArchiveModel
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

    /// Narrow enough to keep a laptop usable with the tray open; the split
    /// can be dragged wider up to `maxWidth`. MainView owns the width and
    /// remembers it — the tray is told its width, never measured for it,
    /// so the stored value can't be overwritten by whatever a layout pass
    /// happened to produce.
    static let minWidth: CGFloat = 300
    static let maxWidth: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $archive.tab) {
                Text("Scan").tag(ArchiveModel.Tab.scan)
                Text(queueTitle).tag(ArchiveModel.Tab.queue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            .help("Scan: the archive, show, inventory and scanning controls. Queue: every send and its progress.")
            Divider()
            switch archive.tab {
            case .scan: scanTab
            case .queue: queueTab
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var queueTitle: String {
        let active = archive.activeJobCount
        let failed = archive.failedJobCount
        if active == 0 && failed == 0 { return "Queue" }
        var parts: [String] = []
        if active > 0 { parts.append("\(active) sending") }
        if failed > 0 { parts.append("\(failed) failed") }
        return "Queue · " + parts.joined(separator: ", ")
    }

    // MARK: - Scan tab

    private var scanTab: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                feedback
                section("Archive API") { archiveSection }
                if archive.isSignedIn {
                    section("Scanner", required: true) { scannerSection }
                    section("Active Show") { showSection }
                    if archive.currentShow != nil {
                        section("Show Inventory") { inventorySection }
                        if let run = archive.run {
                            section("Scanning") { scanningSection(run) }
                            section("Scanned") { scannedSection(run, scrollTo: proxy) }
                        } else {
                            section("Add Assets") { addAssetsSection }
                        }
                    }
                } else if let run = archive.run {
                    // Signed out mid-row: the row is kept, and shown, so it's
                    // clear what signing back in resumes.
                    section("Scanning") { scanningSection(run) }
                }
            }
            .padding(12)
        }
        }
    }

    /// A prominent heading over a card. `required` adds a red star, the
    /// usual mark for a field that must be filled.
    private func section<Content: View>(_ title: String, required: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text(title) + (required ? Text(" *").foregroundColor(.red) : Text("")))
                .font(.title3.weight(.semibold))
            content()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = archive.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { archive.dismissError() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Dismiss this message")
            }
            .padding(8)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        if let status = archive.status {
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: Archive API

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(archive.isSignedIn ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                    .help(archive.isSignedIn ? "Connected: this device is signed in to the archive"
                                             : "Not connected: sign in below")
                VStack(alignment: .leading, spacing: 2) {
                    if archive.isSignedIn {
                        Text("Signed in as \(archive.login)").font(.callout)
                        Text(archive.baseURLText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("This device: \(archive.device)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not connected").font(.callout)
                        Text("Sign in once per device; the archive emails a one-time code.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if archive.isSignedIn {
                    Button("Sign Out") { Task { await archive.signOut() } }
                        .disabled(archive.isBusy)
                        .help("Forget this device's token, here and on the server. The queue and the hot row are kept.")
                }
            }
            if !archive.isSignedIn {
                LabeledContent("API") {
                    TextField("https://host/api/v1", text: $archive.baseURLText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .help("The archive's API address, including /api/v1. On the development machine: http://127.0.0.1:5050/api/v1")
                }
                LabeledContent("Login") {
                    TextField("scanner", text: $archive.login)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .help("Your archive login")
                }
                LabeledContent("Password") {
                    SecureField("", text: $archive.password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if archive.auth == .signedOut { Task { await archive.requestCode() } } }
                        .help("Your archive password. Never stored: after sign-in a device token stands in for it.")
                }
                LabeledContent("Device") {
                    TextField("scanning station", text: $archive.device)
                        .textFieldStyle(.roundedBorder)
                        .help("A name for this computer, as it will appear in the archive's list of signed-in devices")
                }
                if archive.auth == .codeSent {
                    LabeledContent("Code") {
                        TextField("from the email", text: $archive.code)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await archive.signIn() } }
                            .help("The one-time code the archive just emailed. Good for 10 minutes, used once.")
                    }
                    HStack {
                        Button("Cancel") { archive.cancelCode() }
                            .help("Go back without signing in")
                        Spacer()
                        Button("Send Again") { Task { await archive.requestCode() } }
                            .disabled(archive.isBusy)
                            .help("Email a fresh code. Limited to five an hour.")
                        Button("Sign In") { Task { await archive.signIn() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(archive.isBusy || archive.code.trimmingCharacters(in: .whitespaces).isEmpty)
                            .help("Exchange login, password and code for this device's token")
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Send Code") { Task { await archive.requestCode() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(archive.isBusy || archive.login.isEmpty || archive.password.isEmpty)
                            .help("Check the login and password, and email a one-time code")
                    }
                }
            }
            if archive.isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Scanner

    /// Which machine this is, from the archive's own list. Every transfer
    /// names it; the archive refuses one that doesn't.
    private var scannerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $archive.selectedScanner) {
                    Text("Choose…").tag(Int?.none)
                    ForEach(archive.eligibleScanners) { s in
                        Text(s.name).tag(Int?.some(s.id))
                    }
                }
                .labelsHidden()
                .help("The scanning machine this station is, as the archive knows it. Sent with every scan; the archive files each scan under it.")
                Button { Task { await archive.loadScanners() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .disabled(archive.isLoadingScanners)
                    .help("Reload the list of scanners from the archive")
            }
            if archive.isLoadingScanners {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Active Show

    @ViewBuilder
    private var showSection: some View {
        if let show = archive.currentShow {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    // Half again the usual sizes: this is the one thing on
                    // the panel an operator reads from across the room.
                    Text(show.displayName)
                        .font(.system(size: 20, weight: .semibold))
                        .help("The show every capture is filed under")
                    Text(show.id)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let note = show.notes?.public, !note.isEmpty {
                        Text(Self.linkedNote(note))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .environment(\.openURL, OpenURLAction { url in
                                guard url.scheme == Self.noteLinkScheme,
                                      let term = url.host?.removingPercentEncoding else { return .systemAction }
                                archive.searchFromNote(term)
                                return .handled
                            })
                            .help("The show's notes. A [bracketed] phrase is a link: click it to search for it.")
                    }
                }
                Spacer()
                Button("Change") { archive.clearShow() }
                    .help(archive.run != nil
                          ? "Finish the row being scanned and pick a different show"
                          : "Work on a different show")
            }
        } else if archive.isCreatingShow {
            createShowForm
        } else {
            searchForm
        }
    }

    private var searchForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search or Create a show", text: $archive.showQuery)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onAppear {
                    // After Change the field is new to the hierarchy, so the
                    // focus is asked for here, once it exists.
                    if archive.wantsSearchFocus {
                        archive.wantsSearchFocus = false
                        DispatchQueue.main.async { searchFocused = true }
                    }
                }
                .help("A show code (T316 finds T00316) or any words from a show's name or notes")
            if archive.isSearching {
                ProgressView().controlSize(.small)
            }
            if !archive.showResults.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(archive.showResults) { show in
                        Button {
                            Task { await archive.select(show: show) }
                        } label: {
                            HStack {
                                Text(show.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(show.displayName).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                        .help("Work on \(show.id)")
                        Divider()
                    }
                }
                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                // Shows share names — there are several "Kiss Me, Kate" under
                // different codes — so finding some is no proof the one in
                // hand exists. The way to make a new one stays offered.
                HStack {
                    Spacer()
                    Button("Add New…") { archive.beginCreateShow() }
                        .buttonStyle(.link)
                        .help("None of these is it: create a new show, named from what you typed")
                }
            } else if archive.nothingFound {
                Text("No shows match").font(.caption).foregroundStyle(.secondary)
                Button("Create Show") { archive.beginCreateShow() }
                    .help("Make a new show from what you typed, with an empty inventory")
            }
        }
    }

    private var createShowForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Code") {
                TextField("T316", text: $archive.createCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .help("The show code to assign: a category letter and a number, like T316. The archive pads it to T00316.")
            }
            LabeledContent("Name") {
                TextField("Show name", text: $archive.createName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await archive.finishCreateShow() } }
                    .help("The show's name")
            }
            HStack {
                Button("Cancel") { archive.cancelCreateShow() }
                    .help("Back to searching")
                Spacer()
                Button("Finish") { Task { await archive.finishCreateShow() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(archive.isBusy || !archive.createCodeIsValid)
                    .help("Create the show and make it the active show")
            }
        }
    }

    private static let noteLinkScheme = "filmtether-search"

    /// The note as attributed text, each [bracketed] phrase a link that
    /// carries its own term in a private URL scheme the card handles.
    private static func linkedNote(_ note: String) -> AttributedString {
        var out = AttributedString()
        for segment in NoteLinks.segments(note) {
            var piece = AttributedString(segment.text)
            if let term = segment.term,
               let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
               let url = URL(string: "\(noteLinkScheme)://\(encoded)") {
                piece.link = url
            }
            out += piece
        }
        return out
    }

    // MARK: Show Inventory

    private var inventorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Click a row to scan it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { Task { await archive.loadInventory() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .disabled(archive.isLoadingInventory)
                    .help("Reload the inventory from the archive")
            }
            if archive.isLoadingInventory, archive.inventory == nil {
                ProgressView().controlSize(.small)
            } else if let inv = archive.inventory {
                let populated = inv.types.filter { !$0.ranges.isEmpty }
                if populated.isEmpty {
                    Text("No assets in inventory")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                ForEach(populated) { type in
                    Text(type.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(type.ranges, id: \.self) { range in
                        inventoryRow(type, range)
                    }
                }
            }
        }
    }

    private func inventoryRow(_ type: InventoryType, _ range: InventoryRange) -> some View {
        let hot = isHot(type, range)
        return Button {
            // The hot row again: done with it for now, same as Finish.
            if hot { archive.finish() } else { Task { await archive.start(type: type, range: range) } }
        } label: {
            HStack(spacing: 0) {
                // The hot row wears the capture button's colour down its left
                // edge, on a lighter tinted ground: it's where the captures go.
                Rectangle()
                    .fill(hot ? Color.accentColor : Color.clear)
                    .frame(width: 4)
                HStack {
                    Text(range.format ?? "—").lineLimit(1)
                    Spacer()
                    if let roll = range.roll, !roll.isEmpty {
                        Text("roll \(roll)").foregroundStyle(.secondary)
                    }
                    Text(range.range)
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(coverageColor(type, range))
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
            }
            .contentShape(Rectangle())
            .background(hot ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(archive.isBusy)
        .help(coverageText(type, range) + (hot ? " Captures are going to these assets. Click again to finish with them for now."
                  : " Click to scan them: every capture goes to them, starting at \(range.range.split(separator: "-").first.map(String.init) ?? range.range)."))
    }

    /// Green when every frame of the row has a scan in the archive, red when
    /// none has, yellow in between.
    private func coverageColor(_ type: InventoryType, _ range: InventoryRange) -> Color {
        guard let c = archive.coverage(of: type, range), c.total > 0 else { return .secondary }
        if c.scanned == 0 { return .red }
        if c.scanned == c.total { return .green }
        return .yellow
    }

    private func coverageText(_ type: InventoryType, _ range: InventoryRange) -> String {
        guard let c = archive.coverage(of: type, range) else { return "" }
        return "\(c.scanned) of \(c.total) scanned."
    }

    /// The inventory row the captures are going to: same type and roll as
    /// the run, and numbers that overlap it. Overlap rather than equality
    /// because the server merges adjacent runs — add 5-8 next to an existing
    /// 1-4 and the inventory reports 1-8.
    private func isHot(_ type: InventoryType, _ range: InventoryRange) -> Bool {
        guard let run = archive.run, run.type == type.type,
              (range.roll ?? "").uppercased() == (run.roll ?? ""),
              let r = NumberRange.parse(range.range) else { return false }
        let mine = Set((0..<run.range.count).map { run.range.label(at: $0) })
        return (0..<r.count).contains { mine.contains(r.label(at: $0)) }
    }

    // MARK: Add Assets

    private var addAssetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Type") {
                Picker("", selection: $archive.formType) {
                    ForEach(archive.types) { t in
                        Text(t.displayName).tag(t.type)
                    }
                }
                .labelsHidden()
                .help("What these assets are — negatives, prints, and so on. The list is the archive's own.")
            }
            LabeledContent("Format") {
                Picker("", selection: $archive.formFormatID) {
                    ForEach(archive.formats) { f in
                        Text(f.name).tag(f.id)
                    }
                }
                .labelsHidden()
                .help("The film size, by the archive's own list")
            }
            LabeledContent("Roll") {
                TextField("A", text: $archive.formRoll)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .help("Roll letter, A to Z, or blank for none")
            }
            LabeledContent("Numbers") {
                HStack {
                    TextField("first", text: $archive.formFirst)
                        .textFieldStyle(.roundedBorder)
                        .help("First number, e.g. 1 — or 12A for a suffixed frame")
                    Text("to").foregroundStyle(.secondary)
                    TextField("last", text: $archive.formLast)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await archive.addAssets() } }
                        .help("Last number, e.g. 120. Leave blank for a single asset. 12A to 12C is a run of suffixes on one number.")
                }
                .font(.body.monospacedDigit())
            }
            HStack {
                if let r = archive.formRange {
                    Text("\(r.count) asset\(r.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Assets") { Task { await archive.addAssets() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(archive.isBusy || archive.formRange == nil)
                    .help("Register these assets with the archive so they appear in the inventory above. Click the row there to scan it.")
            }
        }
    }

    // MARK: Scanning

    private func scanningSection(_ run: ScanRun) -> some View {
        // The one row every capture is going to, and it should look like it:
        // a bar down the left in the capture button's own colour (the system
        // accent, which is what `.borderedProminent` paints it), on a lighter
        // tinted ground.
        let tint: Color = run.isFinished ? .gray : .accentColor
        return HStack(spacing: 0) {
            Rectangle()
                .fill(tint)
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 10) {
                Text(run.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(archive.archivedSummary(of: run))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Frames of this row that already have a scan in the archive")
                Toggle("Emulsion Up", isOn: Binding(get: { settings.emulsionUp }, set: { model.setEmulsionUp($0) }))
                    .toggleStyle(.checkbox)
                    .help("The film is lying emulsion-up — the rule. On this rig that makes the capture a mirror image, so the preview is mirrored back and each scan is sent with flop so the archive does the same. Untick for a strip lying emulsion-down, which needs no mirror.")
                if run.isFinished {
                    Text("Row finished")
                        .font(.title2.weight(.semibold))
                        .help("Every frame in this row has been scanned or skipped")
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Next")
                            .foregroundStyle(.secondary)
                        Text(run.currentPadded ?? "")
                            .font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .help("The frame the next capture will be filed under")
                        Spacer()
                    }
                    if let id = run.currentDisplayID {
                        // The name the next capture will be filed under. Red when
                        // the archive already holds a scan under it — sending
                        // would overwrite — and − / + step the version until it
                        // isn't. That is the operator's control over overwrites.
                        let taken = archive.targetExists(run)
                        HStack(spacing: 6) {
                            Text(id)
                                .font(.caption.monospaced())
                                .foregroundStyle(taken ? Color.red : Color.secondary)
                                .textSelection(.enabled)
                                .help(taken
                                      ? "The archive already holds a scan under this name: sending would overwrite it. Press + to file this scan as a new version instead."
                                      : "The name the next capture will be filed under (version \(String(format: "%02d", run.currentVersion))). A JPEG alongside the RAW goes to the version after.")
                            Button("−") { archive.stepVersion(-1) }
                                .controlSize(.mini)
                                .disabled(run.currentVersion == 0)
                                .help("Previous version number")
                            Button("+") { archive.stepVersion(1) }
                                .controlSize(.mini)
                                .disabled(run.currentVersion >= 99)
                                .help("Next version number: file the scan as a new version rather than over an existing one")
                        }
                    }
                }
                Text("\(run.scanned.count) scanned · \(run.skipped.count) skipped · \(run.remaining) to go")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Back") { archive.stepBack() }
                        .disabled(run.position == 0)
                        .help("Step back one frame to redo the previous one")
                    Button("Skip") { archive.skipNumber() }
                        .disabled(run.isFinished)
                        .help("This frame isn't there right now: move on without a capture, leaving the asset in place")
                    Button("Remove") { Task { await archive.removeCurrent() } }
                        .disabled(run.isFinished || archive.isBusy)
                        .help("This negative doesn't exist — the strip was miscounted. Take the asset out of the row, and out of the archive if this station may delete.")
                    Spacer()
                    TextField("№", text: $archive.setNumberText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .font(.body.monospacedDigit())
                        .onSubmit { archive.applySetNumber() }
                        .help("A frame to jump to: a number, or a letter in a suffix run")
                    Button("Go") { archive.applySetNumber() }
                        .disabled(archive.setNumberText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Jump to that frame")
                }
                HStack {
                    Spacer()
                    Button("Finish") { archive.finish() }
                        .help("Done with this row for now. Captures stop being filed to it; the row stays in the inventory and can be scanned again later.")
                }
            }
            .padding(12)
        }
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        // The section frame adds its own padding and border; this card is
        // its own, so pull the outer ones back in.
        .padding(-10)
    }


    // MARK: Scanned

    /// The hot row's scanned frames in row order, each the width of the
    /// panel. Lazy: a picture is fetched when its cell scrolls into view,
    /// so a long row doesn't load hundreds of images unasked.
    private static let blockLinkScheme = "filmtether-scanned"

    /// "1-20, 26-35, 55" — the scanned frames as blocks, each a link that
    /// scrolls the list to the block's first frame.
    private func blocksLine(_ blocks: [ArchiveModel.ScannedBlock]) -> AttributedString {
        var out = AttributedString()
        for (i, block) in blocks.enumerated() {
            if i > 0 { out += AttributedString(", ") }
            var piece = AttributedString(block.text)
            if let url = URL(string: "\(Self.blockLinkScheme)://\(block.firstAssetID)") { piece.link = url }
            out += piece
        }
        return out
    }

    private func scannedSection(_ run: ScanRun, scrollTo proxy: ScrollViewProxy) -> some View {
        let frames = archive.frames(of: run)
        let blocks = archive.scannedBlocks(of: run)
        return Group {
            if frames.isEmpty {
                Text("Thumbnails appear here as frames are scanned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // The scanned inventory: which blocks are in, and a way to
                // jump to any of them without scrolling past the rest.
                Text(blocksLine(blocks))
                    .font(.callout.monospacedDigit())
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == Self.blockLinkScheme, let id = url.host else { return .systemAction }
                        withAnimation { proxy.scrollTo(id, anchor: .top) }
                        return .handled
                    })
                    .help("The frames scanned so far, as blocks. Click one to jump to its first frame below.")
                    .padding(.bottom, 6)
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(frames) { f in
                        scannedCell(f, in: run)
                            .id(f.assetID)
                            .onAppear { archive.requestThumbnail(for: f, in: run) }
                    }
                }
            }
        }
    }

    private func scannedCell(_ f: ArchiveModel.Frame, in run: ScanRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let t = f.thumbnail {
                Image(nsImage: t.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.quaternaryLabelColor))
                    .frame(maxWidth: .infinity)
                    .aspectRatio(3 / 2, contentMode: .fit)
                    .overlay(ProgressView().controlSize(.small))
            }
            // One caption, and which one says where the picture came from:
            // the frame number while it's a local rendering, the archive's
            // filename once its own derivative has taken over.
            let filed = f.thumbnail?.source == .archive
            Text(filed ? f.assetID : NumberRange.pad(f.label))
                .font(.callout.monospacedDigit().weight(.semibold))
                .textSelection(.enabled)
                .help(filed ? "\(NumberRange.pad(f.label)): the archive's thumbnail, under its filename"
                            : "\(NumberRange.pad(f.label)): made here from the local file; the archive's filename appears once its derivative exists")
        }
    }

    // MARK: - Queue tab

    private var queueTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text(queueSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Finished") { archive.clearFinished() }
                    .controlSize(.small)
                    .disabled(!archive.jobs.contains { $0.isDone })
                    .help("Remove sent and filed entries from the list")
            }
            .padding(12)
            Divider()
            if archive.jobs.isEmpty {
                Spacer()
                Text("Nothing sent yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(archive.jobs.reversed()) { job in
                        jobRow(job)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var queueSummary: String {
        let done = archive.jobs.filter { $0.isDone }.count
        return "\(archive.jobs.count) total · \(archive.activeJobCount) in progress · \(done) sent · \(archive.failedJobCount) failed"
    }

    private func jobRow(_ job: UploadJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.assetID).font(.callout.monospaced())
                Spacer()
                stateBadge(job)
            }
            Text(job.fileURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if job.isActive {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
            }
            HStack {
                Text(job.stateLabel)
                    .font(.caption)
                    .foregroundStyle(jobIsFailed(job) ? .red : .secondary)
                    .lineLimit(2)
                if let err = job.renderError {
                    Text("Derivatives: \(err)").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if jobIsFailed(job) {
                    Button("Retry") { archive.retry(job) }
                        .controlSize(.small)
                        .help("Send this file again. An interrupted send resumes from the blocks the server still lacks.")
                }
                Button { archive.remove(job) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .help(job.isDone ? "Remove from the list" : "Give up on this send")
            }
        }
        .padding(.vertical, 4)
        .help("\(job.assetID) — \(job.stateLabel)")
    }

    private func jobIsFailed(_ job: UploadJob) -> Bool {
        if case .failed = job.state { return true }
        return false
    }

    @ViewBuilder
    private func stateBadge(_ job: UploadJob) -> some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary).help("Waiting its turn")
        case .hashing, .sending: ProgressView().controlSize(.small).help("Sending")
        case .complete: Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help("Sent; the archive is building its derivatives")
        case .rendered: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Filed, with derivatives")
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).help("Failed; see why below")
        }
    }
}
