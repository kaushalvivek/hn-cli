/// Fetches a user profile.
public struct FetchUserProfile: Sendable {
    private let users: any UserProvider

    public init(users: any UserProvider) {
        self.users = users
    }

    public func callAsFunction(_ id: UserID) async throws -> User? {
        try await users.user(id: id)
    }
}
