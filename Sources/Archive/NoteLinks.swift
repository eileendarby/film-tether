import Foundation

/// The archive's notes cross-reference in square brackets — "with [Cole
/// Porter] at the [Alvin]" — and each bracketed phrase is something worth
/// searching for. This splits a note into plain text and link terms.
public enum NoteLinks {
    public struct Segment: Equatable, Sendable {
        public var text: String
        /// The search term, for a bracketed phrase; nil for plain text.
        public var term: String?
        public init(text: String, term: String? = nil) {
            self.text = text
            self.term = term
        }
    }

    /// "[Cole] wrote it" → [link "Cole", text " wrote it"]. Empty brackets
    /// and an unclosed one are left as plain text.
    public static func segments(_ note: String) -> [Segment] {
        var out: [Segment] = []
        var rest = Substring(note)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            let before = rest[..<open]
            let term = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if term.isEmpty {
                out.append(Segment(text: String(rest[..<rest.index(after: close)])))
            } else {
                if !before.isEmpty { out.append(Segment(text: String(before))) }
                out.append(Segment(text: term, term: term))
            }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { out.append(Segment(text: String(rest))) }
        return out
    }
}
