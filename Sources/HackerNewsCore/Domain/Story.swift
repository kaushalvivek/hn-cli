import Foundation

/// A link or text submission, including Ask HN and Show HN posts.
public struct Story: Sendable, Hashable {
    public let title: HTMLText
    public let url: URL?
    public let text: HTMLText?
    public let score: Int
    public let commentCount: Int
    public let commentIDs: [ItemID]

    public init(
        title: HTMLText,
        url: URL? = nil,
        text: HTMLText? = nil,
        score: Int = 0,
        commentCount: Int = 0,
        commentIDs: [ItemID] = []
    ) {
        self.title = title
        self.url = url
        self.text = text
        self.score = score
        self.commentCount = commentCount
        self.commentIDs = commentIDs
    }
}
