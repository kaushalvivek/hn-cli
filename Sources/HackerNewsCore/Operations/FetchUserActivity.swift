/// Fetches a page of user activity (comments, favorites, upvoted, hidden).
public struct FetchUserActivity: Sendable {
    private let activity: any UserActivityProvider

    public init(activity: any UserActivityProvider) {
        self.activity = activity
    }

    public func callAsFunction(
        userID: UserID,
        kind: UserActivityKind,
        page: PageRequest = .default
    ) async throws -> ItemPage {
        try await activity.items(for: userID, activity: kind, page: page)
    }
}
