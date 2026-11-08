/// Public and authenticated actions on news.ycombinator.com.
///
/// Hacker News has no official write API. Implementations use the site's
/// session cookies and per-page tokens, so every method may throw
/// `HackerNewsError.unauthenticated`, `.unauthorized`, `.unsupported`, or a
/// transport error.
public protocol AccountProvider: Sendable {
    /// The current session, or `nil` when signed out.
    func currentSession() async -> UserSession?

    func logIn(_ credentials: Credentials) async throws -> UserSession
    func signUp(_ credentials: Credentials) async throws -> UserSession
    func logOut() async throws

    func vote(on itemID: ItemID, direction: VoteDirection) async throws

    /// Returns the new item ID when Hacker News exposes it.
    func submitStory(_ submission: StorySubmission) async throws -> ItemID?

    /// Returns the new comment ID when Hacker News exposes it.
    func submitComment(_ submission: CommentSubmission) async throws -> ItemID?
    func editItem(id: ItemID, text: String) async throws
    func deleteItem(id: ItemID) async throws
    func setFavorite(_ isFavorite: Bool, on itemID: ItemID) async throws
    func setHidden(_ isHidden: Bool, on itemID: ItemID) async throws
    func flag(itemID: ItemID, reason: String) async throws
    func unflag(itemID: ItemID) async throws
}
