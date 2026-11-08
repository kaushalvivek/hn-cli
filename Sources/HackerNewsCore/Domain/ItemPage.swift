/// A page of hydrated items plus its position in the source list.
public struct ItemPage: Sendable, Hashable {
    public let items: [Item]
    public let offset: Int
    public let hasMore: Bool
    public let totalCount: Int?

    public init(items: [Item], offset: Int, hasMore: Bool, totalCount: Int? = nil) {
        self.items = items
        self.offset = offset
        self.hasMore = hasMore
        self.totalCount = totalCount
    }
}

/// A page of item IDs returned by a feed source.
public struct ItemIDPage: Sendable, Hashable {
    public let ids: [ItemID]
    public let offset: Int
    public let hasMore: Bool
    public let totalCount: Int?

    public init(ids: [ItemID], offset: Int, hasMore: Bool, totalCount: Int? = nil) {
        self.ids = ids
        self.offset = offset
        self.hasMore = hasMore
        self.totalCount = totalCount
    }
}
