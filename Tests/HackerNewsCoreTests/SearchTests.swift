import Testing
@testable import HackerNewsCore

@Test func searchResultsKnowWhenThereAreMorePages() {
    let first = SearchResults(hits: [], totalHits: 100, page: 0, pageCount: 4, query: "swift")
    #expect(first.hasMore)

    let last = SearchResults(hits: [], totalHits: 100, page: 3, pageCount: 4, query: "swift")
    #expect(last.hasMore == false)
}

@Test func searchQueryDefaultsToStoriesByRelevance() {
    let query = SearchQuery(terms: "swift")
    #expect(query.kinds == [.story])
    #expect(query.sort == .relevance)
    #expect(query.page == .default)
}

@Test func searchOperationDelegatesToProvider() async throws {
    let results = SearchResults(hits: [], totalHits: 0, page: 0, pageCount: 0, query: "swift")
    let search = SearchHackerNews(provider: StubSearchProvider(results: results))
    let response = try await search(SearchQuery(terms: "swift"))
    #expect(response.query == "swift")
    #expect(response.totalHits == 0)
}
