import Foundation
import HackerNewsCore

/// An item parsed from a Hacker News feed page.
public struct SiteFeedEntry: Sendable {
    public let id: ItemID
    public let kind: ItemKind
    public let title: String?
    public let url: URL?
    public let text: HTMLText?
    public let author: UserID?
    public let createdAt: Date
    public let score: Int?
    public let commentCount: Int?
    public let storyID: ItemID?
    public let storyTitle: String?
    public let parentID: ItemID?
    public let isDead: Bool
    public let isDeleted: Bool

    public init(
        id: ItemID,
        kind: ItemKind,
        title: String?,
        url: URL?,
        text: HTMLText?,
        author: UserID?,
        createdAt: Date,
        score: Int?,
        commentCount: Int?,
        storyID: ItemID?,
        storyTitle: String?,
        parentID: ItemID?,
        isDead: Bool,
        isDeleted: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.text = text
        self.author = author
        self.createdAt = createdAt
        self.score = score
        self.commentCount = commentCount
        self.storyID = storyID
        self.storyTitle = storyTitle
        self.parentID = parentID
        self.isDead = isDead
        self.isDeleted = isDeleted
    }
}

public struct SiteFeedPage: Sendable {
    public let entries: [SiteFeedEntry]
    public let offset: Int
    public let hasMore: Bool
    public let totalCount: Int?

    public init(entries: [SiteFeedEntry], offset: Int, hasMore: Bool, totalCount: Int? = nil) {
        self.entries = entries
        self.offset = offset
        self.hasMore = hasMore
        self.totalCount = totalCount
    }
}
