import Testing
@testable import HackerNewsCore

@Test func feedPagePreservesSourceOrderAndPaginates() async throws {
    let items = StubItemProvider(items: [
        ItemID(1): Fixture.story(1),
        ItemID(2): Fixture.story(2),
        ItemID(3): Fixture.story(3),
        ItemID(5): Fixture.story(5),
    ])
    let fetch = FetchFeedPage(
        feeds: StubFeedProvider(ids: [ItemID(1), ItemID(2), ItemID(3), ItemID(4), ItemID(5)]),
        items: items
    )

    let page = try await fetch(
        feed: .frontPage,
        page: try PageRequest(offset: 1, limit: 2)
    )

    #expect(page.items.map(\.id) == [ItemID(2), ItemID(3)])
    #expect(page.items.map { $0.title?.rawHTML } == ["A story", "A story"])
    #expect(page.offset == 1)
    #expect(page.hasMore)
    #expect(page.totalCount == 5)
}

@Test func feedPageOmitsMissingItemsButKeepsTotalCount() async throws {
    let fetch = FetchFeedPage(
        feeds: StubFeedProvider(ids: [ItemID(1), ItemID(2), ItemID(3)]),
        items: StubItemProvider(items: [ItemID(1): Fixture.story(1)])
    )

    let page = try await fetch(feed: .new)

    #expect(page.items.map(\.id) == [ItemID(1)])
    #expect(page.hasMore == false)
    #expect(page.totalCount == 3)
}

@Test func feedPageBeyondTheEndIsEmpty() async throws {
    let fetch = FetchFeedPage(
        feeds: StubFeedProvider(ids: [ItemID(1), ItemID(2)]),
        items: StubItemProvider(items: [
            ItemID(1): Fixture.story(1),
            ItemID(2): Fixture.story(2),
        ])
    )

    let page = try await fetch(
        feed: .frontPage,
        page: try PageRequest(offset: 10, limit: 5)
    )

    #expect(page.items.isEmpty)
    #expect(page.hasMore == false)
    #expect(page.totalCount == 2)
}

@Test func feedPageOfEmptyFeed() async throws {
    let fetch = FetchFeedPage(
        feeds: StubFeedProvider(ids: []),
        items: StubItemProvider(items: [:])
    )

    let page = try await fetch(feed: .ask)

    #expect(page.items.isEmpty)
    #expect(page.hasMore == false)
    #expect(page.totalCount == 0)
}
