import Foundation
import HackerNewsCore

/// Composition root that routes each capability to Firebase, Algolia, or the
/// Hacker News site adapter.
public struct HackerNewsClient: Sendable {
    public let firebase: FirebaseClient
    public let algolia: AlgoliaClient
    public let site: HackerNewsSiteClient

    public init(
        firebase: FirebaseClient = FirebaseClient(),
        algolia: AlgoliaClient = AlgoliaClient(),
        site: HackerNewsSiteClient = HackerNewsSiteClient()
    ) {
        self.firebase = firebase
        self.algolia = algolia
        self.site = site
    }

    public func validateSession() async throws -> UserSession? {
        try await site.validateSession()
    }
}

extension HackerNewsClient: ItemProvider {
    public func item(id: ItemID) async throws -> Item? {
        try await firebase.item(id: id)
    }
}

extension HackerNewsClient: UserProvider {
    public func user(id: UserID) async throws -> User? {
        try await firebase.user(id: id)
    }
}

extension HackerNewsClient: FeedProvider {
    public func itemIDs(for feed: Feed, page: PageRequest) async throws -> ItemIDPage {
        switch feed {
        case .frontPage, .new, .best, .ask, .show, .jobs:
            let ids = try await firebase.itemIDs(forFirebaseFeed: feed)
            guard page.offset < ids.count else {
                return ItemIDPage(ids: [], offset: page.offset, hasMore: false, totalCount: ids.count)
            }
            let end = min(page.offset + page.limit, ids.count)
            return ItemIDPage(
                ids: Array(ids[page.offset..<end]),
                offset: page.offset,
                hasMore: end < ids.count,
                totalCount: ids.count
            )
        case .active, .latestComments, .noobStories, .noobComments, .pastFrontPage, .fromSite:
            return try await site.itemIDs(for: feed, page: page)
        }
    }
}

extension HackerNewsClient: SearchProvider {
    public func search(_ query: SearchQuery) async throws -> SearchResults {
        try await algolia.search(query)
    }
}

extension HackerNewsClient: UpdateProvider {
    public func updates() async throws -> Updates {
        try await firebase.updates()
    }

    public func maxItemID() async throws -> ItemID {
        try await firebase.maxItemID()
    }
}

extension HackerNewsClient: LeaderboardProvider {
    public func leaders() async throws -> [LeaderboardEntry] {
        let entries = try await site.leaders()

        // The leaders page leaves the top ten totals blank. Fill them in from
        // the public profiles so the CLI output is consistent.
        var result: [LeaderboardEntry] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            if entry.karma > 0 {
                result.append(entry)
            } else if let user = try? await firebase.user(id: entry.userID) {
                result.append(LeaderboardEntry(userID: entry.userID, karma: user.karma))
            } else {
                result.append(entry)
            }
        }
        return result
    }
}

extension HackerNewsClient: UserActivityProvider {
    public func items(
        for userID: UserID,
        activity: UserActivityKind,
        page: PageRequest
    ) async throws -> ItemPage {
        let idPage: ItemIDPage

        switch activity {
        case .submissions:
            guard let user = try await firebase.user(id: userID) else {
                throw HackerNewsError.notFound(.user(userID))
            }
            let ids = user.submittedItemIDs
            guard page.offset < ids.count else {
                return ItemPage(items: [], offset: page.offset, hasMore: false, totalCount: ids.count)
            }
            let end = min(page.offset + page.limit, ids.count)
            idPage = ItemIDPage(
                ids: Array(ids[page.offset..<end]),
                offset: page.offset,
                hasMore: end < ids.count,
                totalCount: ids.count
            )

        case .comments:
            idPage = try await algolia.itemIDs(
                tags: ["comment", "author_\(userID.rawValue)"],
                sort: .date,
                page: page
            )

        case .favoriteStories, .favoriteComments, .upvoted, .hidden:
            idPage = try await site.itemIDs(for: userID, activity: activity, page: page)
        }

        let items = try await ItemHydrator.hydrate(ids: idPage.ids, using: firebase, maxConcurrency: 30)
        return ItemPage(
            items: items,
            offset: idPage.offset,
            hasMore: idPage.hasMore,
            totalCount: idPage.totalCount
        )
    }
}

extension HackerNewsClient: AccountProvider {
    public func currentSession() async -> UserSession? {
        await site.currentSession()
    }

    public func logIn(_ credentials: Credentials) async throws -> UserSession {
        try await site.logIn(credentials)
    }

    public func signUp(_ credentials: Credentials) async throws -> UserSession {
        try await site.signUp(credentials)
    }

    public func logOut() async throws {
        try await site.logOut()
    }

    public func vote(on itemID: ItemID, direction: VoteDirection) async throws {
        try await site.vote(on: itemID, direction: direction)
    }

    public func submitStory(_ submission: StorySubmission) async throws -> ItemID? {
        try await site.submitStory(submission)
    }

    public func submitComment(_ submission: CommentSubmission) async throws -> ItemID? {
        try await site.submitComment(submission)
    }

    public func editItem(id: ItemID, text: String) async throws {
        try await site.editItem(id: id, text: text)
    }

    public func deleteItem(id: ItemID) async throws {
        try await site.deleteItem(id: id)
    }

    public func setFavorite(_ isFavorite: Bool, on itemID: ItemID) async throws {
        try await site.setFavorite(isFavorite, on: itemID)
    }

    public func setHidden(_ isHidden: Bool, on itemID: ItemID) async throws {
        try await site.setHidden(isHidden, on: itemID)
    }

    public func flag(itemID: ItemID, reason: String) async throws {
        try await site.flag(itemID: itemID, reason: reason)
    }

    public func unflag(itemID: ItemID) async throws {
        try await site.unflag(itemID: itemID)
    }
}
