import Foundation
import HackerNewsCore

/// Public read-only adapter for the official Hacker News Firebase API.
public struct FirebaseClient: Sendable {
    private let http: any HTTPClient
    private let baseURL: URL
    private let decoder: JSONDecoder

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = URL(string: ProcessInfo.processInfo.environment["HN_FIREBASE_URL"] ?? "https://hacker-news.firebaseio.com/v0/")!
    ) {
        self.http = http
        self.baseURL = baseURL
        self.decoder = JSONDecoder()
    }

    public func item(id: ItemID) async throws -> Item? {
        let response = try await get("item/\(id.rawValue).json")
        if response.text.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return nil
        }
        return try decode(FirebaseItemDTO.self, from: response).toDomain()
    }

    public func user(id: UserID) async throws -> User? {
        let encoded = FormEncoding.escape(id.rawValue)
        let response = try await get("user/\(encoded).json")
        if response.text.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return nil
        }
        return try decode(FirebaseUserDTO.self, from: response).toDomain()
    }

    public func itemIDs(forFirebaseFeed feed: Feed) async throws -> [ItemID] {
        let endpoint: String
        switch feed {
        case .frontPage: endpoint = "topstories.json"
        case .new: endpoint = "newstories.json"
        case .best: endpoint = "beststories.json"
        case .ask: endpoint = "askstories.json"
        case .show: endpoint = "showstories.json"
        case .jobs: endpoint = "jobstories.json"
        case .active, .latestComments, .noobStories, .noobComments, .pastFrontPage, .fromSite:
            throw HackerNewsError.unsupported("Feed \(feed) is not available through Firebase")
        }

        let response = try await get(endpoint)
        let ids = try decode([Int].self, from: response)
        return ids.compactMap(ItemID.init(validating:))
    }

    public func updates() async throws -> Updates {
        let response = try await get("updates.json")
        let updates = try decode(FirebaseUpdatesDTO.self, from: response)
        return Updates(
            itemIDs: (updates.items ?? []).compactMap(ItemID.init(validating:)),
            profileIDs: (updates.profiles ?? []).compactMap(UserID.init(validating:))
        )
    }

    public func maxItemID() async throws -> ItemID {
        let response = try await get("maxitem.json")
        let raw = try decode(Int.self, from: response)
        guard let id = ItemID(validating: raw) else {
            throw HackerNewsError.decoding("Firebase maxitem is not a positive item id")
        }
        return id
    }

    private func get(_ path: String) async throws -> HTTPResponse {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw HackerNewsError.invalidInput("Invalid Firebase path: \(path)")
        }
        let response = try await http.send(HTTPRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw HackerNewsError.server(statusCode: response.statusCode)
        }
        return response
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        do {
            return try decoder.decode(type, from: response.body)
        } catch {
            throw HackerNewsError.decoding("Could not decode Firebase response: \(error)")
        }
    }
}

extension FirebaseClient: ItemProvider {}
