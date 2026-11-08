/// Searches Hacker News.
public struct SearchHackerNews: Sendable {
    private let provider: any SearchProvider

    public init(provider: any SearchProvider) {
        self.provider = provider
    }

    public func callAsFunction(_ query: SearchQuery) async throws -> SearchResults {
        try await provider.search(query)
    }
}
