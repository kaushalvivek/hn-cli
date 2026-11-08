import Foundation

/// A job posting.
public struct Job: Sendable, Hashable {
    public let title: HTMLText
    public let url: URL?
    public let text: HTMLText?
    public let score: Int

    public init(
        title: HTMLText,
        url: URL? = nil,
        text: HTMLText? = nil,
        score: Int = 0
    ) {
        self.title = title
        self.url = url
        self.text = text
        self.score = score
    }
}
