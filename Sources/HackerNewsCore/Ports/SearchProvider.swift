/// Searches Hacker News content.
public protocol SearchProvider: Sendable {
    func search(_ query: SearchQuery) async throws -> SearchResults
}
