/// Moderation and authoring state attached to every item.
public struct ItemFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The author deleted the item. Content and author are usually absent.
    public static let deleted = ItemFlags(rawValue: 1 << 0)

    /// The item was killed or hidden by moderation.
    public static let dead = ItemFlags(rawValue: 1 << 1)

    public var isDeleted: Bool { contains(.deleted) }
    public var isDead: Bool { contains(.dead) }
    public var isVisible: Bool { !isDeleted && !isDead }
}
