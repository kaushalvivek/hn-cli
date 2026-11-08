/// Fetches user activity pages: submissions, comments, favorites, upvoted and
/// hidden items.
public protocol UserActivityProvider: Sendable {
    func items(
        for userID: UserID,
        activity: UserActivityKind,
        page: PageRequest
    ) async throws -> ItemPage
}
