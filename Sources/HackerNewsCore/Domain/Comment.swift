/// A reply to a story or another comment.
///
/// Deleted comments are represented as `Item.Content.deleted` instead, so a
/// live comment always has text. Dead comments keep their content and carry
/// `ItemFlags.dead`.
public struct Comment: Sendable, Hashable {
    public let parentID: ItemID
    public let text: HTMLText
    public let childIDs: [ItemID]

    public init(parentID: ItemID, text: HTMLText, childIDs: [ItemID] = []) {
        self.parentID = parentID
        self.text = text
        self.childIDs = childIDs
    }
}
