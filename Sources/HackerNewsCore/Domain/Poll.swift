/// A poll and its options.
public struct Poll: Sendable, Hashable {
    public let title: HTMLText
    public let text: HTMLText?
    public let score: Int
    public let commentCount: Int
    public let commentIDs: [ItemID]
    public let optionIDs: [ItemID]

    public init(
        title: HTMLText,
        text: HTMLText? = nil,
        score: Int = 0,
        commentCount: Int = 0,
        commentIDs: [ItemID] = [],
        optionIDs: [ItemID] = []
    ) {
        self.title = title
        self.text = text
        self.score = score
        self.commentCount = commentCount
        self.commentIDs = commentIDs
        self.optionIDs = optionIDs
    }
}
