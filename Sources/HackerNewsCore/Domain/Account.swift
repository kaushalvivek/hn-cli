import Foundation

/// A vote action on an item.
public enum VoteDirection: String, Sendable, Hashable, Codable {
    case up
    case down
    case unvote
}

/// A username/password pair used to establish a session.
///
/// Intentionally not `Codable` or `Hashable`: credentials should not be
/// persisted or logged by the domain.
public struct Credentials: Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) throws {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            throw HackerNewsError.invalidInput("Username must not be empty")
        }
        guard !password.isEmpty else {
            throw HackerNewsError.invalidInput("Password must not be empty")
        }
        self.username = trimmedUsername
        self.password = password
    }
}

/// The signed-in account. Authentication tokens and cookies stay in the
/// transport adapter.
public struct UserSession: Sendable, Hashable {
    public let userID: UserID

    public init(userID: UserID) {
        self.userID = userID
    }
}

/// A story submission. Exactly one of `url` or `text` must be present.
public struct StorySubmission: Sendable, Hashable {
    public let title: String
    public let url: URL?
    public let text: String?

    public init(title: String, url: URL? = nil, text: String? = nil) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw HackerNewsError.invalidInput("Story title must not be empty")
        }

        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url != nil || (trimmedText?.isEmpty == false) else {
            throw HackerNewsError.invalidInput("A story needs a URL or text")
        }

        self.title = trimmedTitle
        self.url = url
        self.text = trimmedText?.isEmpty == false ? trimmedText : nil
    }
}

/// A comment or reply.
public struct CommentSubmission: Sendable, Hashable {
    public let parentID: ItemID
    public let text: String

    public init(parentID: ItemID, text: String) throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw HackerNewsError.invalidInput("Comment text must not be empty")
        }
        self.parentID = parentID
        self.text = trimmedText
    }
}

/// A page of a user's activity.
public enum UserActivityKind: String, Sendable, Hashable, Codable {
    /// Stories, polls, and comments submitted by the user (Firebase).
    case submissions

    /// Comments by the user (site `threads` page).
    case comments

    /// Stories the user has favorited.
    case favoriteStories

    /// Comments the user has favorited.
    case favoriteComments

    /// Items the signed-in user has upvoted. Requires a session.
    case upvoted

    /// Items the signed-in user has hidden. Requires a session.
    case hidden
}
