import Foundation

/// The "hot row": the strip of negatives being worked through right now.
///
/// Once a run is set, every capture goes to the asset at the current
/// position and the position advances, so the operator's whole loop is "move
/// the film, press capture". A frame that isn't there (the missing number
/// 34) is skipped without a capture; a mistake is fixed by jumping to a
/// label. Positions, not numbers, so a run of suffixes (`12A-12C`) steps the
/// same way as a run of numbers.
///
/// Asset ids are never composed here. They come back from the server when
/// the run is registered — one per label for the RAW (version `00`) — and
/// are looked up by label. The JPEG's `01` versions are registered as each
/// capture produces one, and remembered here so a redo reuses them.
public struct ScanRun: Codable, Equatable, Sendable {
    public var show: String
    public var showName: String?
    /// Asset type letter, "N" for a negative.
    public var type: String
    public var typeName: String?
    public var roll: String?
    /// Film size id, the archive database's own.
    public var format: Int
    public var formatName: String?
    public var range: NumberRange
    /// Index into `range` of the frame the next capture will be filed under.
    public var position: Int
    /// label ("12A") → assetid of version 00, the RAW.
    public var assetIDs: [String: String]
    /// label → assetid of version 01, the JPEG, filled in as they're registered.
    public var secondaryAssetIDs: [String: String]
    public var scanned: [String]
    public var skipped: [String]
    public var started: Date

    public init(show: String, showName: String? = nil, type: String, typeName: String? = nil,
                roll: String?, format: Int, formatName: String? = nil,
                range: NumberRange, assetIDs: [String: String], started: Date = Date()) {
        self.show = show
        self.showName = showName
        self.type = type
        self.typeName = typeName
        self.roll = roll?.isEmpty == true ? nil : roll?.uppercased()
        self.format = format
        self.formatName = formatName
        self.range = range
        self.position = 0
        self.assetIDs = Dictionary(uniqueKeysWithValues: assetIDs.map { (NumberRange.normalize($0.key), $0.value) })
        self.secondaryAssetIDs = [:]
        self.scanned = []
        self.skipped = []
        self.started = started
    }

    /// Every frame has been scanned or skipped.
    public var isFinished: Bool { position >= range.count }

    /// `"12A"` — the label of the frame the next capture goes to.
    public var currentLabel: String? {
        isFinished ? nil : range.label(at: position)
    }

    /// `"0012A"` — the same, padded for display.
    public var currentPadded: String? {
        currentLabel.map(NumberRange.pad)
    }

    public func assetID(for label: String) -> String? {
        assetIDs[NumberRange.normalize(label)]
    }

    /// The RAW's asset for the next capture, or nil once the run is finished.
    public var currentAssetID: String? {
        currentLabel.flatMap(assetID(for:))
    }

    /// Record that the current frame was captured, and move on.
    public mutating func markScanned() {
        guard let label = currentLabel else { return }
        scanned.append(label)
        position += 1
    }

    /// Move on without a capture — the frame isn't there.
    public mutating func skip() {
        guard let label = currentLabel else { return }
        skipped.append(label)
        position += 1
    }

    /// Jump to a position. Out-of-range values are ignored, so a typo can't
    /// put the run somewhere it has no assets for. `range.count` is allowed:
    /// that's "finished".
    public mutating func jump(to i: Int) {
        guard i >= 0, i <= range.count else { return }
        position = i
    }

    /// Jump to a typed label ("34", "0034", "12B", or "B" in a suffix run).
    /// Returns false if it isn't in the run.
    @discardableResult
    public mutating func jump(toLabel text: String) -> Bool {
        guard let i = range.index(of: text) else { return false }
        position = i
        return true
    }

    /// Step back one, to redo the previous frame.
    public mutating func back() {
        jump(to: position - 1)
    }

    /// "T00316 · Negative · roll A · 120mm Rollei · 1-120"
    public var summary: String {
        var parts = [show, typeName ?? type]
        if let roll { parts.append("roll \(roll)") }
        if let formatName { parts.append(formatName) }
        parts.append(range.description)
        return parts.joined(separator: " · ")
    }

    public var remaining: Int {
        max(0, range.count - position)
    }
}
