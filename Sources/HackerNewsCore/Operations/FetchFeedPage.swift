/// Fetches one page of a feed and hydrates its items.
public struct FetchFeedPage: Sendable {
    private let feeds: any FeedProvider
    private let items: any ItemProvider
    private let maxConcurrency: Int

    public init(
        feeds: any FeedProvider,
        items: any ItemProvider,
        maxConcurrency: Int = 16
    ) {
        self.feeds = feeds
        self.items = items
        self.maxConcurrency = max(1, maxConcurrency)
    }

    public func callAsFunction(
        feed: Feed,
        page: PageRequest = .default
    ) async throws -> ItemPage {
        let idPage = try await feeds.itemIDs(for: feed, page: page)
        return try await ItemPageLoader.hydrate(
            ids: idPage.ids,
            offset: page.offset,
            hasMore: idPage.hasMore,
            totalCount: idPage.totalCount,
            using: items,
            maxConcurrency: maxConcurrency
        )
    }
}
