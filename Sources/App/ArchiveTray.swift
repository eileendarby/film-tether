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

    static let width: CGFloat = 360

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
        .frame(width: Self.width)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                feedback
                section("Archive API") { archiveSection }
                if archive.isSignedIn {
                    section("Active Show") { showSection }
                    if archive.currentShow != nil {
                        section("Show Inventory") { inventorySection }
                        if let run = archive.run {
                            section("Scanning") { scanningSection(run) }
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

    /// A prominent heading over a card.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
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

    // MARK: Active Show

    @ViewBuilder
    private var showSection: some View {
        if let show = archive.currentShow {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(show.displayName).font(.headline)
                    Text(show.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let venue = show.notes?.public, !venue.isEmpty {
                        Text(venue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Change") { archive.clearShow() }
                    .disabled(archive.run != nil)
                    .help(archive.run != nil ? "Finish the row being scanned first" : "Work on a different show")
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
            Task { await archive.start(type: type, range: range) }
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
                    Text(range.range).font(.body.monospacedDigit())
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
        .help(hot ? "Captures are going to these assets"
                  : "Scan these assets: every capture goes to them, starting at \(range.range.split(separator: "-").first.map(String.init) ?? range.range)")
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
                    if let id = run.currentAssetID {
                        Text(id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .help("The archive's asset id for that frame")
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
                        .help("This frame isn't there: move on without a capture")
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
