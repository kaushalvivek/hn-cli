/// Fetches the top users by karma.
public struct FetchLeaders: Sendable {
    private let provider: any LeaderboardProvider

    public init(provider: any LeaderboardProvider) {
        self.provider = provider
    }

    public func callAsFunction() async throws -> [LeaderboardEntry] {
        try await provider.leaders()
    }
}
