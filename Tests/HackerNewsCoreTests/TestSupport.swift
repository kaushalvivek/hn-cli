import Foundation
@testable import HackerNewsCore

enum Fixture {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func story(
        _ id: Int,
        author: String = "alice",
        kids: [Int] = [],
        title: String = "A story",
        score: Int = 10,
        commentCount: Int? = nil
    ) -> Item {
        Item(
            id: ItemID(id),
            author: UserID(author),
            createdAt: date,
            content: .story(
                Story(
                    title: HTMLText(title),
                    url: URL(string: "https://example.com/\(id)"),
                    score: score,
                    commentCount: commentCount ?? kids.count,
                    commentIDs: kids.map { ItemID($0) }
                )
            )
        )
    }

    static func comment(
        _ id: Int,
        parent: Int,
        kids: [Int] = [],
        dead: Bool = false
    ) -> Item {
        Item(
            id: ItemID(id),
            author: UserID("commenter"),
            createdAt: date,
            flags: dead ? .dead : [],
            content: .comment(
                Comment(
                    parentID: ItemID(parent),
                    text: HTMLText("Comment \(id)"),
                    childIDs: kids.map { ItemID($0) }
                )
            )
        )
    }

    static func deleted(
        _ id: Int,
        parent: Int,
        kids: [Int] = []
    ) -> Item {
        Item(
            id: ItemID(id),
            createdAt: date,
            flags: .deleted,
            content: .deleted(
                DeletedItem(
                    parentID: ItemID(parent),
                    childIDs: kids.map { ItemID($0) }
                )
            )
        )
    }
}

struct StubItemProvider: ItemProvider {
    let items: [ItemID: Item]

    func item(id: ItemID) async throws -> Item? {
        items[id]
    }
}

struct StubFeedProvider: FeedProvider {
    let ids: [ItemID]

    func itemIDs(for feed: Feed, page: PageRequest) async throws -> ItemIDPage {
        let slice = Array(page.slice(of: ids))
        return ItemIDPage(
            ids: slice,
            offset: page.offset,
            hasMore: page.offset + slice.count < ids.count,
            totalCount: ids.count
        )
    }
}

struct StubUserProvider: UserProvider {
    let users: [UserID: User]

    func user(id: UserID) async throws -> User? {
        users[id]
    }
}

struct StubSearchProvider: SearchProvider {
    let results: SearchResults

    func search(_ query: SearchQuery) async throws -> SearchResults {
        results
    }
}

struct StubUpdateProvider: UpdateProvider {
    let updatesValue: Updates
    let maxItemIDValue: ItemID

    func updates() async throws -> Updates {
        updatesValue
    }

    func maxItemID() async throws -> ItemID {
        maxItemIDValue
    }
}
