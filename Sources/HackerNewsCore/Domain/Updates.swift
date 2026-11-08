/// Items and profiles that changed since Hacker News last reported updates.
public struct Updates: Sendable, Hashable {
    public let itemIDs: [ItemID]
    public let profileIDs: [UserID]

    public init(itemIDs: [ItemID] = [], profileIDs: [UserID] = []) {
        self.itemIDs = itemIDs
        self.profileIDs = profileIDs
    }
}
