import Foundation

/// A run of asset numbers in the archive's notation, and the order to step
/// through them.
///
/// Two shapes, matching what the register endpoint accepts:
///
/// - **numbers** — `1-4`, `12`, `0001-0120`, `12A-14A`: the number steps,
///   with at most one suffix letter carried across the whole run.
/// - **suffixes** — `12A-12C`: one number, and the suffix letter steps.
///
/// Varying both at once is refused, as the server refuses it. Either shape
/// is a list of labels (`"12"`, `"12A"`, `"13A"`…) addressed by position, so a
/// scanning run steps the same way through both.
public struct NumberRange: Equatable, Hashable, Codable, Sendable {
    public enum Kind: Equatable, Hashable, Codable, Sendable {
        case numbers(first: Int, last: Int, suffix: String?)
        case suffixes(number: Int, first: String, last: String)
    }

    public var kind: Kind

    /// A run of numbers, optionally all carrying one suffix.
    public init?(first: Int, last: Int, suffix: String? = nil) {
        guard first >= 0, last >= first else { return nil }
        if let s = suffix { guard Self.isLetter(s) else { return nil } }
        kind = .numbers(first: first, last: last, suffix: suffix?.uppercased())
    }

    /// One number, a run of suffixes.
    public init?(number: Int, firstSuffix: String, lastSuffix: String) {
        guard number >= 0, Self.isLetter(firstSuffix), Self.isLetter(lastSuffix) else { return nil }
        let a = firstSuffix.uppercased(), b = lastSuffix.uppercased()
        guard a <= b else { return nil }
        kind = .suffixes(number: number, first: a, last: b)
    }

    private static func isLetter(_ s: String) -> Bool {
        s.count == 1 && s.first!.isLetter && s.first!.isASCII
    }

    public var count: Int {
        switch kind {
        case .numbers(let first, let last, _): return last - first + 1
        case .suffixes(_, let first, let last): return Int(last.unicodeScalars.first!.value - first.unicodeScalars.first!.value) + 1
        }
    }

    /// The label at a position, in the API's own notation: `"12"`, `"12A"`.
    public func label(at i: Int) -> String {
        precondition(i >= 0 && i < count, "position out of range")
        switch kind {
        case .numbers(let first, _, let suffix):
            return "\(first + i)\(suffix ?? "")"
        case .suffixes(let number, let first, _):
            let scalar = first.unicodeScalars.first!.value + UInt32(i)
            return "\(number)\(Character(UnicodeScalar(scalar)!))"
        }
    }

    /// `"0012A"` — the archive's padded form, for display.
    public func paddedLabel(at i: Int) -> String {
        Self.pad(label(at: i))
    }

    public var firstLabel: String { label(at: 0) }
    public var lastLabel: String { label(at: count - 1) }

    /// "1-4", "12", "12A-14A", "12A-12C" — the inventory's own notation.
    public var description: String {
        count == 1 ? firstLabel : "\(firstLabel)-\(lastLabel)"
    }

    /// The position of a label the operator typed, or nil if it isn't in
    /// the run. Accepts padded or not (`"34"`, `"0034"`, `"0012a"`), and for
    /// a suffix run a bare letter (`"B"`).
    public func index(of text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !t.isEmpty else { return nil }
        if case .suffixes(let number, let first, _) = kind, t.count == 1, t.first!.isLetter {
            return index(of: "\(number)\(t)")
        }
        let wanted = Self.normalize(t)
        for i in 0..<count where label(at: i) == wanted { return i }
        return nil
    }

    /// `"0012A"` → `"12A"`, so labels from the server (padded) and from the
    /// operator (usually not) compare equal.
    public static func normalize(_ number: String) -> String {
        let s = number.trimmingCharacters(in: .whitespaces).uppercased()
        let digits = s.prefix { $0.isNumber }
        let rest = s.dropFirst(digits.count)
        let n = Int(digits).map(String.init) ?? String(digits)
        return n + rest
    }

    /// `"12A"` → `"0012A"`.
    public static func pad(_ label: String) -> String {
        let digits = label.prefix { $0.isNumber }
        let rest = label.dropFirst(digits.count)
        guard let n = Int(digits) else { return label }
        return String(format: "%04d", n) + rest
    }

    /// Parse "1-4", "12", " 0001 - 0120 ", "12A-14A", "12A-12C". Nil for
    /// anything else, including a run that varies number and suffix at once.
    public static func parse(_ text: String) -> NumberRange? {
        let parts = text.uppercased()
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 1 || parts.count == 2 else { return nil }
        guard let a = parseEnd(parts[0]) else { return nil }
        let b = parts.count == 2 ? parseEnd(parts[1]) : a
        guard let b else { return nil }
        if a.suffix == b.suffix {
            return NumberRange(first: a.number, last: b.number, suffix: a.suffix)
        }
        if a.number == b.number, let sa = a.suffix, let sb = b.suffix {
            return NumberRange(number: a.number, firstSuffix: sa, lastSuffix: sb)
        }
        return nil
    }

    /// "0012A" → (12, "A"); "7" → (7, nil).
    static func parseEnd(_ s: String) -> (number: Int, suffix: String?)? {
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        let tail = s.dropFirst(digits.count)
        if tail.isEmpty { return (n, nil) }
        guard tail.count == 1, let c = tail.first, c.isLetter else { return nil }
        return (n, String(c))
    }
}
