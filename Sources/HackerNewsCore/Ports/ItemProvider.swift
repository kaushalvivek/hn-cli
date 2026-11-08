/// Fetches individual items.
public protocol ItemProvider: Sendable {
    /// Returns `nil` when Hacker News has no item with this ID.
    func item(id: ItemID) async throws -> Item?
}
