import Foundation

/// A show identifier as the archive composes it: a category letter, five
/// padded digits and an optional suffix letter — `T00316`, `T00316A`.
///
/// Operators type these loosely ("t316", "T-316", "T 00316 a"), so parsing
/// is forgiving; composing is exact, because the composed form is what goes
/// into a URL path and has to match the server's own.
public struct ShowCode: Equatable, Hashable, Sendable {
    public var category: String
    public var number: Int
    public var suffix: String?

    public init(category: String, number: Int, suffix: String? = nil) {
        self.category = category.uppercased()
        self.number = number
        self.suffix = suffix?.uppercased()
    }

    /// `T00316A`
    public var id: String {
        String(format: "%@%05d%@", category, number, suffix ?? "")
    }

    /// Parse operator input. Returns nil for anything that isn't one letter,
    /// some digits and at most one trailing letter, ignoring spaces, hyphens
    /// and underscores between them.
    public static func parse(_ text: String) -> ShowCode? {
        let cleaned = text.uppercased().filter { !" -_".contains($0) }
        guard let first = cleaned.first, first.isLetter, first.isASCII else { return nil }
        let rest = cleaned.dropFirst()
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 5, let number = Int(digits) else { return nil }
        let tail = rest.dropFirst(digits.count)
        if tail.isEmpty {
            return ShowCode(category: String(first), number: number)
        }
        guard tail.count == 1, let s = tail.first, s.isLetter, s.isASCII else { return nil }
        return ShowCode(category: String(first), number: number, suffix: String(s))
    }
}
