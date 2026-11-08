/// Fetches the current largest item ID, the high-water mark for discovering
/// new items.
public struct FetchMaxItemID: Sendable {
    private let provider: any UpdateProvider

    public init(provider: any UpdateProvider) {
        self.provider = provider
    }

    public func callAsFunction() async throws -> ItemID {
        try await provider.maxItemID()
    }
}
