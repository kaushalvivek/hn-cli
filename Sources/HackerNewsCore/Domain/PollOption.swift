/// One option in a poll.
public struct PollOption: Sendable, Hashable {
    public let pollID: ItemID
    public let text: HTMLText
    public let score: Int

    public init(pollID: ItemID, text: HTMLText, score: Int = 0) {
        self.pollID = pollID
        self.text = text
        self.score = score
    }
}
