/// Text from a Hacker News field that contains HTML.
///
/// The raw HTML is preserved verbatim. Rendering it as plain text (CLI) or
/// attributed text (iOS) is a presentation concern.
public struct HTMLText: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawHTML: String

    public init(_ rawHTML: String) {
        self.rawHTML = rawHTML
    }

    public var isEmpty: Bool { rawHTML.isEmpty }

    public var description: String { rawHTML }

    public static let empty = HTMLText("")
}
