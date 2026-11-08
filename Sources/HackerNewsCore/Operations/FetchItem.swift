/// Fetches a single item.
public struct FetchItem: Sendable {
    private let items: any ItemProvider

    public init(items: any ItemProvider) {
        self.items = items
    }

    public func callAsFunction(_ id: ItemID) async throws -> Item? {
        try await items.item(id: id)
    }
}
