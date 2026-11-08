import Foundation
import Testing
import HackerNewsCore
@testable import HackerNewsAdapters

private let searchJSON = """
{
  "hits": [
    {
      "objectID": "43700607",
      "author": "healsdata",
      "title": "CVE program faces swift end",
      "url": "https://example.com/cve",
      "created_at_i": 1744768647,
      "points": 1934,
      "num_comments": 1094,
      "_tags": ["story", "author_healsdata", "story_43700607"]
    },
    {
      "objectID": "9999994",
      "author": "dford87",
      "comment_text": "Hiring iOS engineers <p>Apply now",
      "story_title": "Ask HN: Who is hiring?",
      "story_id": 9996333,
      "parent_id": 9996333,
      "created_at_i": 1438637488,
      "_tags": ["comment", "author_dford87", "story_9996333"]
    }
  ],
  "nbHits": 100,
  "page": 0,
  "nbPages": 50,
  "hitsPerPage": 2,
  "query": "swift"
}
"""

@Test func algoliaMapsStoryAndCommentHits() async throws {
    let mock = MockHTTPClient { request in
        makeResponse(for: request, body: searchJSON)
    }
    let client = AlgoliaClient(http: mock)
    let results = try await client.search(
        SearchQuery(terms: "swift", kinds: [.story, .comment], page: try PageRequest(offset: 0, limit: 2))
    )

    #expect(results.totalHits == 100)
    #expect(results.page == 0)
    #expect(results.pageCount == 50)
    #expect(results.hasMore)

    #expect(results.hits.count == 2)
    #expect(results.hits[0].kind == .story)
    #expect(results.hits[0].title?.rawHTML == "CVE program faces swift end")
    #expect(results.hits[0].score == 1934)
    #expect(results.hits[1].kind == .comment)
    #expect(results.hits[1].storyTitle?.rawHTML == "Ask HN: Who is hiring?")
    #expect(results.hits[1].parentID == ItemID(9996333))
}

@Test func algoliaBuildsTagsAndNumericFilters() async throws {
    let mock = MockHTTPClient { request in
        makeResponse(for: request, body: searchJSON)
    }
    let client = AlgoliaClient(http: mock)
    _ = try await client.search(
        SearchQuery(
            terms: "swift",
            kinds: [.story, .comment],
            author: UserID("pg"),
            sort: .date,
            page: try PageRequest(offset: 0, limit: 2),
            minimumScore: 10
        )
    )

    let request = try #require(await mock.requests().first)
    #expect(request.url.path == "/api/v1/search_by_date")
    #expect(query(request, "query") == "swift")
    #expect(query(request, "tags") == "(comment,story),author_pg")
    #expect(query(request, "numericFilters") == "points>=10")
    #expect(query(request, "hitsPerPage") == "2")
    #expect(query(request, "page") == "0")
}

@Test func algoliaReturnsItemIDsForTagPages() async throws {
    let mock = MockHTTPClient { request in
        makeResponse(for: request, body: searchJSON)
    }
    let client = AlgoliaClient(http: mock)
    let page = try await client.itemIDs(
        tags: ["comment", "author_pg"],
        sort: .date,
        page: try PageRequest(offset: 0, limit: 2)
    )

    #expect(page.ids == [ItemID(43700607), ItemID(9999994)])
    #expect(page.totalCount == 100)
    #expect(page.hasMore)
}
