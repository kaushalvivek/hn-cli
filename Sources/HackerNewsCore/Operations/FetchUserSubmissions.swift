/// Fetches and hydrates a page of a user's submissions.
public struct FetchUserSubmissions: Sendable {
    private let users: any UserProvider
    private let items: any ItemProvider
    private let maxConcurrency: Int

    public init(
        users: any UserProvider,
        items: any ItemProvider,
        maxConcurrency: Int = 16
    ) {
        self.users = users
        self.items = items
        self.maxConcurrency = max(1, maxConcurrency)
    }

    public func callAsFunction(
        userID: UserID,
        page: PageRequest = .default
    ) async throws -> ItemPage {
        guard let user = try await users.user(id: userID) else {
            throw HackerNewsError.notFound(.user(userID))
        }

        return try await ItemPageLoader.page(
            ids: user.submittedItemIDs,
            page: page,
            using: items,
            maxConcurrency: maxConcurrency
        )
    }
}
