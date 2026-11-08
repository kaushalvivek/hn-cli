/// Loads a root item and its comment tree.
///
/// Hacker News only returns child IDs with each item, so the thread is built by
/// traversing those IDs breadth-first with bounded concurrency. Missing items
/// are skipped and counted; the structural order of the loaded comments is
/// preserved.
public struct LoadThread: Sendable {
    private let items: any ItemProvider

    public init(items: any ItemProvider) {
        self.items = items
    }

    public func callAsFunction(
        rootID: ItemID,
        policy: ThreadLoadPolicy = .default
    ) async throws -> Thread {
        guard let root = try await items.item(id: rootID) else {
            throw HackerNewsError.notFound(.item(rootID))
        }

        struct Request {
            let parentID: ItemID
            let childID: ItemID
            let depth: Int
        }

        var loaded: [ItemID: Item] = [rootID: root]
        var childrenByParent: [ItemID: [ItemID]] = [:]
        var seen: Set<ItemID> = [rootID]
        var queue: [Request] = []
        var missingItemCount = 0
        var truncated = false

        let rootChildIDs = root.childIDs
        if !rootChildIDs.isEmpty {
            if let maxDepth = policy.maxDepth, maxDepth == 0 {
                truncated = true
            } else {
                queue = rootChildIDs.map {
                    Request(parentID: root.id, childID: $0, depth: 1)
                }
            }
        }

        let concurrency = max(1, policy.maxConcurrentRequests)
        var head = 0

        while head < queue.count {
            let availableByNodeLimit: Int
            if let maxNodes = policy.maxNodes {
                availableByNodeLimit = max(0, maxNodes - loaded.count)
            } else {
                availableByNodeLimit = Int.max
            }

            guard availableByNodeLimit > 0 else {
                truncated = true
                break
            }

            let batchCount = min(concurrency, queue.count - head, availableByNodeLimit)
            guard batchCount > 0 else { break }

            let batch = Array(queue[head..<(head + batchCount)])
            head += batchCount

            let loadedBatch = try await ItemLoader.load(
                ids: batch.map(\.childID),
                using: items,
                maxConcurrency: concurrency
            )

            for request in batch {
                guard let item = loadedBatch[request.childID] else {
                    missingItemCount += 1
                    continue
                }
                guard !seen.contains(item.id) else { continue }

                seen.insert(item.id)
                loaded[item.id] = item
                childrenByParent[request.parentID, default: []].append(item.id)

                let childIDs = item.childIDs
                guard !childIDs.isEmpty else { continue }

                if let maxDepth = policy.maxDepth, request.depth >= maxDepth {
                    truncated = true
                } else {
                    queue.append(contentsOf: childIDs.map {
                        Request(parentID: item.id, childID: $0, depth: request.depth + 1)
                    })
                }
            }
        }

        func buildNode(_ id: ItemID) -> ThreadNode? {
            guard let item = loaded[id] else { return nil }
            let replies = (childrenByParent[id] ?? []).compactMap(buildNode)
            return ThreadNode(item: item, replies: replies)
        }

        let replies = (childrenByParent[root.id] ?? []).compactMap(buildNode)

        return Thread(
            root: root,
            replies: replies,
            loadedItemCount: loaded.count,
            missingItemCount: missingItemCount,
            isComplete: !truncated && missingItemCount == 0
        )
    }
}
