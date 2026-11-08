/// Loads a set of items concurrently while preserving bounded concurrency.
enum ItemLoader {
    static func load(
        ids: [ItemID],
        using provider: any ItemProvider,
        maxConcurrency: Int
    ) async throws -> [ItemID: Item] {
        guard !ids.isEmpty else { return [:] }

        var loaded: [ItemID: Item] = [:]
        loaded.reserveCapacity(ids.count)

        let concurrency = max(1, maxConcurrency)

        try await withThrowingTaskGroup(of: (ItemID, Item?).self) { group in
            var nextIndex = 0
            var inFlight = 0

            while inFlight < concurrency, nextIndex < ids.count {
                let id = ids[nextIndex]
                nextIndex += 1
                group.addTask {
                    (id, try await provider.item(id: id))
                }
                inFlight += 1
            }

            while let (id, item) = try await group.next() {
                inFlight -= 1
                if let item {
                    loaded[id] = item
                }

                if nextIndex < ids.count {
                    let id = ids[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        (id, try await provider.item(id: id))
                    }
                    inFlight += 1
                }
            }
        }

        return loaded
    }
}
