import Foundation
import HackerNewsCore
import SwiftSoup

/// Adapter for news.ycombinator.com: HTML reads, session authentication, and
/// authenticated actions.
public actor HackerNewsSiteClient {
    private let http: any HTTPClient
    private let baseURL: URL
    private let sessionStore: any SessionStore
    private var storedSession: StoredSession?
    private var cachedAuthToken: String?

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let maxHTMLPages = 25

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = URL(string: ProcessInfo.processInfo.environment["HN_SITE_URL"] ?? "https://news.ycombinator.com/")!,
        sessionStore: any SessionStore = FileSessionStore()
    ) {
        self.http = http
        self.baseURL = baseURL.absoluteString.hasSuffix("/")
            ? baseURL
            : URL(string: baseURL.absoluteString + "/")!
        self.sessionStore = sessionStore
        self.storedSession = try? sessionStore.load()
    }

    // MARK: - Session

    public func currentSession() async -> UserSession? {
        guard let storedSession else { return nil }
        return UserSession(userID: storedSession.username)
    }

    public func validateSession() async throws -> UserSession? {
        guard storedSession != nil else { return nil }
        let response = try await request("news")
        let document = try HTMLSupport.document(from: response.text)
        if try HTMLSupport.isLoginPage(document) {
            try clearSession()
            return nil
        }
        return await currentSession()
    }

    public func logIn(_ credentials: Credentials) async throws -> UserSession {
        try await authenticate(
            fields: [
                "goto": "news",
                "acct": credentials.username,
                "pw": credentials.password,
            ],
            failure: .invalidCredentials
        )
    }

    public func signUp(_ credentials: Credentials) async throws -> UserSession {
        try await authenticate(
            fields: [
                "creating": "t",
                "goto": "news",
                "acct": credentials.username,
                "pw": credentials.password,
            ],
            failure: .invalidInput("Hacker News rejected the account creation")
        )
    }

    public func logOut() async throws {
        if storedSession != nil {
            if let token = await authToken() {
                _ = try? await request(
                    "logout?auth=\(FormEncoding.escape(token))&goto=news"
                )
            } else {
                _ = try? await request("logout?goto=news")
            }
        }

        try clearSession()
    }

    private func authenticate(
        fields: [String: String],
        failure: HackerNewsError
    ) async throws -> UserSession {
        let response = try await request(
            "login",
            method: "POST",
            fields: fields,
            followRedirects: false,
            sendCookies: false
        )

        let text = response.text
        if text.contains("Bad login") {
            throw HackerNewsError.invalidCredentials
        }
        if text.contains("Validation required") {
            throw HackerNewsError.unsupported("Hacker News requires browser validation to log in")
        }
        if text.contains("Sorry") {
            throw failure
        }

        guard let cookie = Self.userCookie(from: response),
              let username = Self.username(fromCookie: cookie)
        else {
            throw failure
        }

        let session = StoredSession(cookie: cookie, username: username)
        storedSession = session
        cachedAuthToken = nil
        try sessionStore.save(session)
        return UserSession(userID: username)
    }

    private func clearSession() throws {
        storedSession = nil
        cachedAuthToken = nil
        try sessionStore.clear()
    }

    func requireSession() throws -> StoredSession {
        guard let storedSession else {
            throw HackerNewsError.unauthenticated
        }
        return storedSession
    }

    func authToken() async -> String? {
        if let cachedAuthToken {
            return cachedAuthToken
        }

        if let response = try? await request("news"),
           let token = HTMLSupport.authToken(in: response.text) {
            cachedAuthToken = token
            return token
        }

        return storedSession.flatMap { Self.authToken(fromCookie: $0.cookie) }
    }

    // MARK: - Reads

    public func itemIDs(for feed: Feed, page: PageRequest) async throws -> ItemIDPage {
        let path: String
        switch feed {
        case .active:
            path = "active"
        case .latestComments:
            path = "newcomments"
        case .noobStories:
            path = "noobstories"
        case .noobComments:
            path = "noobcomments"
        case .pastFrontPage(let day):
            path = "front?day=\(day)"
        case .fromSite(let site):
            path = "from?site=\(FormEncoding.escape(site))"
        case .frontPage, .new, .best, .ask, .show, .jobs:
            throw HackerNewsError.unsupported("Feed \(feed) is served by Firebase")
        }
        return try await pagedItemIDs(startPath: path, page: page)
    }

    public func itemIDs(
        for userID: UserID,
        activity: UserActivityKind,
        page: PageRequest
    ) async throws -> ItemIDPage {
        let username = FormEncoding.escape(userID.rawValue)
        switch activity {
        case .comments:
            return try await pagedItemIDs(startPath: "threads?id=\(username)", page: page)
        case .favoriteStories:
            return try await pagedItemIDs(startPath: "favorites?id=\(username)", page: page)
        case .favoriteComments:
            return try await pagedItemIDs(startPath: "favorites?id=\(username)&comments=t", page: page)
        case .upvoted:
            let session = try requireSession()
            guard session.username == userID else {
                throw HackerNewsError.unauthorized
            }
            return try await pagedItemIDs(startPath: "upvoted", page: page, authRequired: true)
        case .hidden:
            let session = try requireSession()
            guard session.username == userID else {
                throw HackerNewsError.unauthorized
            }
            return try await pagedItemIDs(startPath: "hidden", page: page, authRequired: true)
        case .submissions:
            throw HackerNewsError.unsupported("Submissions are served by Firebase")
        }
    }

    public func feedEntries(for feed: Feed, page: PageRequest) async throws -> SiteFeedPage {
        let path: String
        let defaultKind: ItemKind
        switch feed {
        case .frontPage:
            path = "news"
            defaultKind = .story
        case .new:
            path = "newest"
            defaultKind = .story
        case .best:
            path = "best"
            defaultKind = .story
        case .ask:
            path = "ask"
            defaultKind = .story
        case .show:
            path = "show"
            defaultKind = .story
        case .jobs:
            path = "jobs"
            defaultKind = .job
        case .active:
            path = "active"
            defaultKind = .story
        case .latestComments:
            path = "newcomments"
            defaultKind = .comment
        case .noobStories:
            path = "noobstories"
            defaultKind = .story
        case .noobComments:
            path = "noobcomments"
            defaultKind = .comment
        case .pastFrontPage(let day):
            path = "front?day=\(day)"
            defaultKind = .story
        case .fromSite(let site):
            path = "from?site=\(FormEncoding.escape(site))"
            defaultKind = .story
        }

        return try await pagedEntries(
            startPath: path,
            page: page,
            defaultKind: defaultKind
        )
    }

    public func activityEntries(
        for userID: UserID,
        activity: UserActivityKind,
        page: PageRequest
    ) async throws -> SiteFeedPage {
        let username = FormEncoding.escape(userID.rawValue)
        let path: String
        let defaultKind: ItemKind
        var authRequired = false

        switch activity {
        case .submissions:
            throw HackerNewsError.unsupported("Submissions are served by Firebase")
        case .comments:
            path = "threads?id=\(username)"
            defaultKind = .comment
        case .favoriteStories:
            path = "favorites?id=\(username)"
            defaultKind = .story
        case .favoriteComments:
            path = "favorites?id=\(username)&comments=t"
            defaultKind = .comment
        case .upvoted:
            let session = try requireSession()
            guard session.username == userID else { throw HackerNewsError.unauthorized }
            path = "upvoted"
            defaultKind = .story
            authRequired = true
        case .hidden:
            let session = try requireSession()
            guard session.username == userID else { throw HackerNewsError.unauthorized }
            path = "hidden"
            defaultKind = .story
            authRequired = true
        }

        return try await pagedEntries(
            startPath: path,
            page: page,
            defaultKind: defaultKind,
            authRequired: authRequired
        )
    }

    public func leaders() async throws -> [LeaderboardEntry] {
        let response = try await request("leaders")
        let document = try HTMLSupport.document(from: response.text)
        return try HTMLSupport.leaders(in: document)
    }

    public func itemHTML(id: ItemID) async throws -> String {
        let response = try await request("item?id=\(id.rawValue)")
        try await ensureNotLoginPage(response)
        return response.text
    }

    // MARK: - HTML paging

    private func pagedEntries(
        startPath: String,
        page: PageRequest,
        defaultKind: ItemKind,
        authRequired: Bool = false
    ) async throws -> SiteFeedPage {
        var path = startPath
        var entries: [SiteFeedEntry] = []
        var seen: Set<ItemID> = []
        var more: String?
        let target = page.offset + page.limit
        var pagesFetched = 0

        while pagesFetched < Self.maxHTMLPages {
            let response = try await request(path)
            if authRequired {
                try await ensureNotLoginPage(response)
            }
            let document = try HTMLSupport.document(from: response.text)
            if authRequired, try HTMLSupport.isLoginPage(document) {
                throw HackerNewsError.unauthenticated
            }

            for entry in try HTMLSupport.feedEntries(in: document, defaultKind: defaultKind)
                where !seen.contains(entry.id)
            {
                seen.insert(entry.id)
                entries.append(entry)
            }

            more = try HTMLSupport.moreLink(in: document)
            pagesFetched += 1

            if entries.count >= target || more == nil {
                break
            }
            path = more!
        }

        guard page.offset < entries.count else {
            return SiteFeedPage(entries: [], offset: page.offset, hasMore: false)
        }

        let end = min(page.offset + page.limit, entries.count)
        let slice = Array(entries[page.offset..<end])
        return SiteFeedPage(
            entries: slice,
            offset: page.offset,
            hasMore: end < entries.count || more != nil,
            totalCount: nil
        )
    }

    private func pagedItemIDs(
        startPath: String,
        page: PageRequest,
        authRequired: Bool = false
    ) async throws -> ItemIDPage {
        var path = startPath
        var ids: [ItemID] = []
        var seen: Set<ItemID> = []
        var more: String?
        let target = page.offset + page.limit
        var pagesFetched = 0

        while pagesFetched < Self.maxHTMLPages {
            let response = try await request(path)
            if authRequired {
                try await ensureNotLoginPage(response)
            }

            let document = try HTMLSupport.document(from: response.text)
            if authRequired, try HTMLSupport.isLoginPage(document) {
                throw HackerNewsError.unauthenticated
            }

            for id in try HTMLSupport.itemIDs(in: document) where !seen.contains(id) {
                seen.insert(id)
                ids.append(id)
            }

            more = try HTMLSupport.moreLink(in: document)
            pagesFetched += 1

            if ids.count >= target || more == nil {
                break
            }
            path = more!
        }

        guard page.offset < ids.count else {
            return ItemIDPage(ids: [], offset: page.offset, hasMore: false)
        }

        let end = min(page.offset + page.limit, ids.count)
        let slice = Array(ids[page.offset..<end])
        return ItemIDPage(
            ids: slice,
            offset: page.offset,
            hasMore: end < ids.count || more != nil,
            totalCount: nil
        )
    }

    // MARK: - HTTP

    func request(
        _ path: String,
        method: String = "GET",
        fields: [String: String]? = nil,
        followRedirects: Bool = true,
        referer: String? = nil,
        sendCookies: Bool = true
    ) async throws -> HTTPResponse {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw HackerNewsError.invalidInput("Invalid Hacker News path: \(path)")
        }

        var headers: [String: String] = [
            "User-Agent": Self.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Origin": baseURL.absoluteString,
            "Referer": referer ?? baseURL.absoluteString,
            "Upgrade-Insecure-Requests": "1",
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "same-origin",
            "Sec-Fetch-User": "?1",
        ]

        var body: Data?
        if let fields {
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            body = Data(FormEncoding.encode(fields).utf8)
        }

        if sendCookies, let cookie = storedSession?.cookie {
            headers["Cookie"] = "user=\(cookie)"
        }

        return try await http.send(
            HTTPRequest(
                method: method,
                url: url,
                headers: headers,
                body: body,
                followRedirects: followRedirects
            )
        )
    }

    func ensureNotLoginPage(_ response: HTTPResponse) async throws {
        if response.finalURL.path.contains("/login") {
            throw HackerNewsError.unauthenticated
        }
        if response.text.contains("name=\"acct\"") && response.text.contains("name=\"pw\"") {
            throw HackerNewsError.unauthenticated
        }
    }

    // MARK: - Cookies

    private static func userCookie(from response: HTTPResponse) -> String? {
        guard let header = response.header("set-cookie") else { return nil }

        if let cookie = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": header],
            for: response.finalURL
        ).first(where: { $0.name == "user" }), !cookie.value.isEmpty {
            return cookie.value
        }

        return HTMLSupport.firstMatch(
            pattern: #"(?:^|,\s*)user=([^;]+)"#,
            in: header
        )
    }

    private static func username(fromCookie cookie: String) -> UserID? {
        let decoded = cookie.removingPercentEncoding ?? cookie
        guard let first = decoded.split(separator: "&").first else { return nil }
        return UserID(validating: String(first))
    }

    private static func authToken(fromCookie cookie: String) -> String? {
        let decoded = cookie.removingPercentEncoding ?? cookie
        let parts = decoded.split(separator: "&")
        guard parts.count >= 2,
              let token = parts.last.map(String.init),
              token.count >= 8
        else {
            return nil
        }
        return token
    }
}
