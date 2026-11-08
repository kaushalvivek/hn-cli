/// A root item and its comment tree.
public struct Thread: Sendable, Hashable {
    public let root: Item
    public let replies: [ThreadNode]

    /// Number of items in the loaded tree, including the root.
    public let loadedItemCount: Int

    /// Number of item IDs that the source could not resolve.
    public let missingItemCount: Int

    /// False when the traversal was truncated by `ThreadLoadPolicy` or an item
    /// could not be fetched.
    public let isComplete: Bool

    public init(
        root: Item,
        replies: [ThreadNode],
        loadedItemCount: Int,
        missingItemCount: Int,
        isComplete: Bool
    ) {
        self.root = root
        self.replies = replies
        self.loadedItemCount = loadedItemCount
        self.missingItemCount = missingItemCount
        self.isComplete = isComplete
    }
}

/// A comment in a loaded thread.
public struct ThreadNode: Sendable, Hashable, Identifiable {
    public let item: Item
    public let replies: [ThreadNode]

    public var id: ItemID { item.id }

    public init(item: Item, replies: [ThreadNode] = []) {
        self.item = item
        self.replies = replies
    }
}

/// Bounds for recursive thread loading.
public struct ThreadLoadPolicy: Sendable, Hashable {
    /// Maximum comment depth. `0` loads only the root. `nil` is unlimited.
    public var maxDepth: Int?

    /// Maximum total items including the root. `nil` is unlimited.
    public var maxNodes: Int?

    /// Number of item requests in flight at once.
    public var maxConcurrentRequests: Int

    public static let `default` = ThreadLoadPolicy()

    public init(
        maxDepth: Int? = nil,
        maxNodes: Int? = 500,
        maxConcurrentRequests: Int = 8
    ) {
        self.maxDepth = maxDepth.map { max(0, $0) }
        self.maxNodes = maxNodes.map { max(1, $0) }
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }
}
