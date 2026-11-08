import Foundation
import HackerNewsCore

/// Adapter for the Algolia Hacker News search API.
public struct AlgoliaClient: Sendable {
    private let http: any HTTPClient
    private let baseURL: URL
    private let decoder: JSONDecoder

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = URL(string: ProcessInfo.processInfo.environment["HN_ALGOLIA_URL"] ?? "https://hn.algolia.com/api/v1/")!
    ) {
        self.http = http
        self.baseURL = baseURL
        self.decoder = JSONDecoder()
    }

    public func search(_ query: SearchQuery) async throws -> SearchResults {
        let window = try await hits(for: query)
        let pageNumber = query.page.offset / query.page.limit
        let pageCount = window.totalHits == 0
            ? 0
            : Int(ceil(Double(window.totalHits) / Double(query.page.limit)))

        return SearchResults(
            hits: try window.hits.map { try $0.toDomain() },
            totalHits: window.totalHits,
            page: pageNumber,
            pageCount: pageCount,
            query: query.terms
        )
    }

    /// Returns a page of item IDs matching the given Algolia tags.
    /// Fetches a full item tree in one request. This is much faster than
    /// walking the Firebase API one comment at a time.
    public func itemTree(id: ItemID) async throws -> HackerNewsCore.Thread {
        guard let url = URL(string: "items/\(id.rawValue)", relativeTo: baseURL) else {
            throw HackerNewsError.invalidInput("Invalid Algolia item URL")
        }
        let response = try await http.send(HTTPRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw HackerNewsError.server(statusCode: response.statusCode)
        }

        do {
            let dto = try decoder.decode(AlgoliaItemDTO.self, from: response.body)
            return try dto.toThread()
        } catch let error as HackerNewsError {
            throw error
        } catch {
            throw HackerNewsError.decoding("Could not decode Algolia item tree: \(error)")
        }
    }

    public func itemIDs(
        tags: [String],
        sort: SearchSort,
        page: PageRequest
    ) async throws -> ItemIDPage {
        let query = SearchQuery(
            terms: "",
            kinds: [],
            sort: sort,
            page: page
        )
        let window = try await hits(
            for: query,
            overrideTags: tags,
            overrideText: nil
        )
        let ids = window.hits.compactMap { hit in
            Int(hit.objectID).flatMap(ItemID.init(validating:))
        }
        return ItemIDPage(
            ids: ids,
            offset: page.offset,
            hasMore: page.offset + ids.count < window.totalHits,
            totalCount: window.totalHits
        )
    }

    private func hits(
        for query: SearchQuery,
        overrideTags: [String]? = nil,
        overrideText: String? = nil
    ) async throws -> (hits: [AlgoliaHit], totalHits: Int) {
        // Algolia caps `hitsPerPage` at 1000. Fetch a window that covers the
        // requested offset when possible, then slice locally.
        let requestedWindow = query.page.offset + query.page.limit
        let pageSize = min(1000, max(query.page.limit, requestedWindow))
        let startPage = requestedWindow <= 1000 ? 0 : query.page.offset / 1000
        var offsetWithinPage = requestedWindow <= 1000 ? query.page.offset : query.page.offset % 1000

        var collected: [AlgoliaHit] = []
        var totalHits = 0
        var page = startPage

        while collected.count < query.page.limit {
            var items: [URLQueryItem] = [
                URLQueryItem(name: "hitsPerPage", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ]

            let text = overrideText ?? query.terms
            if !text.isEmpty {
                items.append(URLQueryItem(name: "query", value: text))
            }

            let tags = overrideTags ?? tags(for: query)
            if !tags.isEmpty {
                items.append(URLQueryItem(name: "tags", value: tags.joined(separator: ",")))
            }

            let numericFilters = numericFilters(for: query)
            if !numericFilters.isEmpty {
                items.append(URLQueryItem(name: "numericFilters", value: numericFilters.joined(separator: ",")))
            }

            let endpoint = query.sort == .date ? "search_by_date" : "search"
            let response = try await get(endpoint, queryItems: items)
            totalHits = response.nbHits

            var pageHits = response.hits
            if offsetWithinPage > 0 {
                let drop = min(offsetWithinPage, pageHits.count)
                pageHits.removeFirst(drop)
                offsetWithinPage -= drop
            }
            collected.append(contentsOf: pageHits)

            if page + 1 >= response.nbPages || response.hits.isEmpty {
                break
            }
            page += 1
        }

        return (Array(collected.prefix(query.page.limit)), totalHits)
    }

    private func tags(for query: SearchQuery) -> [String] {
        var tags: [String] = []

        if !query.kinds.isEmpty {
            let kindTags = query.kinds.map(\.rawValue).sorted()
            if kindTags.count == 1 {
                tags.append(kindTags[0])
            } else {
                tags.append("(\(kindTags.joined(separator: ",")))")
            }
        }

        if let author = query.author {
            tags.append("author_\(author.rawValue)")
        }
        if let storyID = query.storyID {
            tags.append("story_\(storyID.rawValue)")
        }
        return tags
    }

    private func numericFilters(for query: SearchQuery) -> [String] {
        var filters: [String] = []
        if let after = query.createdAfter {
            filters.append("created_at_i>\(Int(after.timeIntervalSince1970))")
        }
        if let before = query.createdBefore {
            filters.append("created_at_i<\(Int(before.timeIntervalSince1970))")
        }
        if let minimumScore = query.minimumScore {
            filters.append("points>=\(minimumScore)")
        }
        if let minimumComments = query.minimumComments {
            filters.append("num_comments>=\(minimumComments)")
        }
        return filters
    }

    private func get(_ path: String, queryItems: [URLQueryItem]) async throws -> AlgoliaSearchResponse {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw HackerNewsError.invalidInput("Invalid Algolia URL")
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw HackerNewsError.invalidInput("Invalid Algolia query")
        }

        let response = try await http.send(HTTPRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw HackerNewsError.server(statusCode: response.statusCode)
        }

        do {
            return try decoder.decode(AlgoliaSearchResponse.self, from: response.body)
        } catch {
            throw HackerNewsError.decoding("Could not decode Algolia response: \(error)")
        }
    }
}
