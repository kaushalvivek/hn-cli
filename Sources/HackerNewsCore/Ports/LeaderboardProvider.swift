/// Provides the top users by karma.
public protocol LeaderboardProvider: Sendable {
    func leaders() async throws -> [LeaderboardEntry]
}
