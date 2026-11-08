import Foundation

/// A Hacker News account with public activity.
public struct User: Sendable, Hashable, Identifiable {
    public let id: UserID
    public let createdAt: Date
    public let karma: Int
    public let about: HTMLText?
    public let submittedItemIDs: [ItemID]

    public init(
        id: UserID,
        createdAt: Date,
        karma: Int,
        about: HTMLText? = nil,
        submittedItemIDs: [ItemID] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.karma = karma
        self.about = about
        self.submittedItemIDs = submittedItemIDs
    }
}
