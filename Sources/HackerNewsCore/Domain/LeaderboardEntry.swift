/// One entry in Hacker News' leaders list (`leaders`).
public struct LeaderboardEntry: Sendable, Hashable {
    public let userID: UserID
    public let karma: Int

    public init(userID: UserID, karma: Int) {
        self.userID = userID
        self.karma = karma
    }
}
