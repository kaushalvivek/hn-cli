/// Provides a page of ordered item IDs for a feed.
///
/// Implementations may use Firebase feed endpoints, Algolia, or HN HTML. The
/// returned order is the feed's display order. Pagination belongs to the
/// provider because HTML feeds have their own page layout.
public protocol FeedProvider: Sendable {
    func itemIDs(for feed: Feed, page: PageRequest) async throws -> ItemIDPage
}
