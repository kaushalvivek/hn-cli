import Foundation

/// Anything addressable by a Hacker News item ID.
///
/// Shared metadata lives here; type-specific fields live in `Content`.
public struct Item: Sendable, Hashable, Identifiable {
    public let id: ItemID
    public let author: UserID?
    public let createdAt: Date
    public let flags: ItemFlags
    public let content: Content

    public init(
        id: ItemID,
        author: UserID? = nil,
        createdAt: Date,
        flags: ItemFlags = [],
        content: Content
    ) {
        self.id = id
        self.author = author
        self.createdAt = createdAt
        self.flags = flags
        self.content = content
    }

    public enum Content: Sendable, Hashable {
        case story(Story)
        case comment(Comment)
        case job(Job)
        case poll(Poll)
        case pollOption(PollOption)
        case deleted(DeletedItem)
    }

    /// The item's kind, or `nil` when its content is no longer available.
    public var kind: ItemKind? {
        switch content {
        case .story: return .story
        case .comment: return .comment
        case .job: return .job
        case .poll: return .poll
        case .pollOption: return .pollOption
        case .deleted: return nil
        }
    }

    /// The parent comment or story, for comments and deleted items that still
    /// carry a parent link.
    public var parentID: ItemID? {
        switch content {
        case .comment(let comment): comment.parentID
        case .deleted(let deleted): deleted.parentID
        case .story, .job, .poll, .pollOption: nil
        }
    }

    /// Child IDs in HN's display order. Empty for items that cannot have
    /// children.
    public var childIDs: [ItemID] {
        switch content {
        case .story(let story): story.commentIDs
        case .comment(let comment): comment.childIDs
        case .poll(let poll): poll.commentIDs
        case .deleted(let deleted): deleted.childIDs
        case .job, .pollOption: []
        }
    }

    public var title: HTMLText? {
        switch content {
        case .story(let story): story.title
        case .job(let job): job.title
        case .poll(let poll): poll.title
        case .comment, .pollOption, .deleted: nil
        }
    }

    public var text: HTMLText? {
        switch content {
        case .story(let story): story.text
        case .comment(let comment): comment.text
        case .job(let job): job.text
        case .poll(let poll): poll.text
        case .pollOption(let option): option.text
        case .deleted: nil
        }
    }

    public var score: Int? {
        switch content {
        case .story(let story): story.score
        case .job(let job): job.score
        case .poll(let poll): poll.score
        case .pollOption(let option): option.score
        case .comment, .deleted: nil
        }
    }

    public var commentCount: Int? {
        switch content {
        case .story(let story): story.commentCount
        case .poll(let poll): poll.commentCount
        case .comment, .job, .pollOption, .deleted: nil
        }
    }

    public var isDeleted: Bool { flags.isDeleted }
    public var isDead: Bool { flags.isDead }
}
