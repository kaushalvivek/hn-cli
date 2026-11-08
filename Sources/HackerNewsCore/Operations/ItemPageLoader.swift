/// Hydrates a page of feed/user IDs, preserving source order.
enum ItemPageLoader {
    static func page(
        ids: [ItemID],
        page: PageRequest,
        using provider: any ItemProvider,
        maxConcurrency: Int
    ) async throws -> ItemPage {
        let sliceIDs = Array(page.slice(of: ids))
        let end = page.offset + sliceIDs.count

        return try await hydrate(
            ids: sliceIDs,
            offset: page.offset,
            hasMore: end < ids.count,
            totalCount: ids.count,
            using: provider,
            maxConcurrency: maxConcurrency
        )
    }

    static func hydrate(
        ids: [ItemID],
        offset: Int,
        hasMore: Bool,
        totalCount: Int?,
        using provider: any ItemProvider,
        maxConcurrency: Int
    ) async throws -> ItemPage {
        let loaded = try await ItemLoader.load(
            ids: ids,
            using: provider,
            maxConcurrency: maxConcurrency
        )
        return ItemPage(
            items: ids.compactMap { loaded[$0] },
            offset: offset,
            hasMore: hasMore,
            totalCount: totalCount
        )
    }
}
