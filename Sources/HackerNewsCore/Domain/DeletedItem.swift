/// An item whose content is no longer available.
///
/// Deleted comments keep their parent and children so a thread can still be
/// rendered with the correct shape.
public struct DeletedItem: Sendable, Hashable {
    public let parentID: ItemID?
    public let childIDs: [ItemID]

    public init(parentID: ItemID? = nil, childIDs: [ItemID] = []) {
        self.parentID = parentID
        self.childIDs = childIDs
    }
}
