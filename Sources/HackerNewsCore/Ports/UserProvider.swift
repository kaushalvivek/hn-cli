/// Fetches user profiles.
public protocol UserProvider: Sendable {
    /// Returns `nil` when the username does not exist or has no public activity.
    func user(id: UserID) async throws -> User?
}
