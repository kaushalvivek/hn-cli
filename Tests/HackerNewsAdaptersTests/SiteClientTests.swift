import Foundation
import Testing
import HackerNewsCore
@testable import HackerNewsAdapters

private func sessionStore() -> InMemorySessionStore {
    InMemorySessionStore(
        session: StoredSession(
            cookie: "alice&abc123def456",
            username: UserID("alice")
        )
    )
}

private func siteClient(
    _ mock: MockHTTPClient,
    store: any SessionStore = InMemorySessionStore()
) -> HackerNewsSiteClient {
    HackerNewsSiteClient(
        http: mock,
        baseURL: URL(string: "https://news.ycombinator.com/")!,
        sessionStore: store
    )
}

@Test func siteLoginStoresSessionAndSendsCookie() async throws {
    let store = InMemorySessionStore()
    let mock = MockHTTPClient { request in
        switch (request.url.path, request.method) {
        case ("/login", "POST"):
            return makeResponse(
                for: request,
                status: 302,
                headers: Fixtures.loginSuccessHeaders,
                body: ""
            )
        case ("/active", "GET"):
            return makeResponse(for: request, body: Fixtures.feedPage)
        default:
            return makeResponse(for: request, status: 404, body: "")
        }
    }

    let client = siteClient(mock, store: store)
    let session = try await client.logIn(
        Credentials(username: "alice", password: "secret")
    )

    #expect(session.userID == UserID("alice"))
    #expect((try store.load())?.cookie == "alice&abc123def456")

    let page = try await client.itemIDs(
        for: .active,
        page: try PageRequest(offset: 0, limit: 2)
    )
    #expect(page.ids == [ItemID(1), ItemID(2)])

    let requests = await mock.requests()
    let activeRequest = try #require(requests.last)
    #expect(activeRequest.headers["Cookie"] == "user=alice&abc123def456")
}

@Test func siteLoginRejectsBadCredentials() async throws {
    let mock = MockHTTPClient { request in
        makeResponse(for: request, body: "<html>Bad login.</html>")
    }
    let client = siteClient(mock)

    do {
        _ = try await client.logIn(Credentials(username: "alice", password: "wrong"))
        Issue.record("Expected invalidCredentials")
    } catch let error as HackerNewsError {
        #expect(error == .invalidCredentials)
    }
}

@Test func siteValidatesAndClearsExpiredSession() async throws {
    let store = sessionStore()
    let mock = MockHTTPClient { request in
        makeResponse(
            for: request,
            body: """
            <html><body>
            <form method="post"><input name="acct"><input type="password" name="pw"></form>
            </body></html>
            """
        )
    }
    let client = siteClient(mock, store: store)

    #expect(try await client.validateSession() == nil)
    #expect(try store.load() == nil)
}

@Test func siteLogoutClearsSession() async throws {
    let store = sessionStore()
    let mock = MockHTTPClient { request in
        if request.url.path == "/logout" {
            return makeResponse(for: request, body: "ok")
        }
        return makeResponse(for: request, status: 404, body: "")
    }
    let client = siteClient(mock, store: store)

    try await client.logOut()

    #expect(try store.load() == nil)
    let requests = await mock.requests()
    let logout = try #require(requests.first(where: { $0.url.path == "/logout" }))
    #expect(query(logout, "auth") == "abc123def456")
}

@Test func sitePaginatesHTMLFeeds() async throws {
    let mock = MockHTTPClient { request in
        if query(request, "next") == "2" {
            return makeResponse(for: request, body: Fixtures.feedPageWithoutMore)
        }
        return makeResponse(for: request, body: Fixtures.feedPage)
    }
    let client = siteClient(mock)

    let page = try await client.itemIDs(
        for: .latestComments,
        page: try PageRequest(offset: 0, limit: 3)
    )

    #expect(page.ids == [ItemID(1), ItemID(2), ItemID(3)])
    #expect(page.hasMore == false)
    #expect(await mock.requests().count == 2)
}

@Test func siteRequiresAuthenticationForUpvoted() async throws {
    let mock = MockHTTPClient { request in
        makeResponse(for: request, body: Fixtures.feedPage)
    }
    let client = siteClient(mock)

    do {
        _ = try await client.itemIDs(
            for: UserID("alice"),
            activity: .upvoted,
            page: .default
        )
        Issue.record("Expected unauthenticated")
    } catch let error as HackerNewsError {
        #expect(error == .unauthenticated)
    }
}

@Test func siteVotesByFollowingTheItemLink() async throws {
    let mock = MockHTTPClient { request in
        if request.url.path == "/item" {
            return makeResponse(for: request, body: Fixtures.votePage)
        }
        if request.url.path == "/vote" {
            return makeResponse(for: request, body: "<html>ok</html>")
        }
        return makeResponse(for: request, status: 404, body: "")
    }
    let client = siteClient(mock, store: sessionStore())

    try await client.vote(on: ItemID(1), direction: .up)

    let requests = await mock.requests()
    #expect(requests.count == 2)
    #expect(requests[0].url.path == "/item")
    #expect(requests[1].url.path == "/vote")
    #expect(query(requests[1], "how") == "up")
    #expect(query(requests[1], "auth") == "abc123")
    #expect(requests[1].headers["Cookie"] == "user=alice&abc123def456")
}

@Test func siteUpvoteUsesPostWhenOnlyUnvoteLinkExists() async throws {
    let mock = MockHTTPClient { request in
        switch request.url.path {
        case "/item":
            return makeResponse(for: request, body: Fixtures.votePageAlreadyVoted)
        case "/news":
            return makeResponse(
                for: request,
                body: "<html><a href=\"logout?auth=abc123\">logout</a></html>"
            )
        case "/vote":
            return makeResponse(for: request, body: "<html>ok</html>")
        default:
            return makeResponse(for: request, status: 404, body: "")
        }
    }
    let client = siteClient(mock, store: sessionStore())

    try await client.vote(on: ItemID(1), direction: .up)

    let requests = await mock.requests()
    let post = try #require(requests.first(where: { $0.url.path == "/vote" }))
    #expect(post.method == "POST")
    #expect(bodyText(post).contains("how=up"))
    #expect(bodyText(post).contains("auth=abc123"))
}

@Test func siteSubmitsStoryWithFormToken() async throws {
    let mock = MockHTTPClient { request in
        switch request.url.path {
        case "/submitlink":
            return makeResponse(for: request, body: Fixtures.submitFormPage)
        case "/r":
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data("<html>ok</html>".utf8),
                finalURL: URL(string: "https://news.ycombinator.com/item?id=42")!
            )
        default:
            return makeResponse(for: request, status: 404, body: "")
        }
    }
    let client = siteClient(mock, store: sessionStore())

    let submission = try StorySubmission(
        title: "A title",
        url: URL(string: "https://example.com")
    )
    let id = try await client.submitStory(submission)

    #expect(id == ItemID(42))
    let requests = await mock.requests()
    let post = try #require(requests.first(where: { $0.url.path == "/r" }))
    let body = bodyText(post)
    #expect(body.contains("fnid=fnid123"))
    #expect(body.contains("fnop=submit-page"))
    #expect(body.contains("title=A%20title"))
    #expect(body.contains("url=https%3A%2F%2Fexample.com"))
}

@Test func sitePostsCommentWithFormToken() async throws {
    let mock = MockHTTPClient { request in
        switch request.url.path {
        case "/item":
            return makeResponse(for: request, body: Fixtures.commentFormPage)
        case "/comment":
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data("<html>ok</html>".utf8),
                finalURL: URL(string: "https://news.ycombinator.com/item?id=1#99")!
            )
        default:
            return makeResponse(for: request, status: 404, body: "")
        }
    }
    let client = siteClient(mock, store: sessionStore())

    let submission = try CommentSubmission(parentID: ItemID(1), text: "hello")
    let id = try await client.submitComment(submission)

    #expect(id == ItemID(99))
    let post = try #require(await mock.requests().first(where: { $0.url.path == "/comment" }))
    let body = bodyText(post)
    #expect(body.contains("hmac=hmac123"))
    #expect(body.contains("parent=1"))
    #expect(body.contains("text=hello"))
}

@Test func siteEditsItemWithHmac() async throws {
    let mock = MockHTTPClient { request in
        switch request.url.path {
        case "/edit":
            return makeResponse(for: request, body: Fixtures.editFormPage)
        case "/xedit":
            return makeResponse(for: request, body: "<html>ok</html>")
        default:
            return makeResponse(for: request, status: 404, body: "")
        }
    }
    let client = siteClient(mock, store: sessionStore())

    try await client.editItem(id: ItemID(1), text: "new text")

    let post = try #require(await mock.requests().first(where: { $0.url.path == "/xedit" }))
    let body = bodyText(post)
    #expect(body.contains("hmac=hmac123"))
    #expect(body.contains("id=1"))
    #expect(body.contains("text=new%20text"))
}

@Test func siteDeletesItemWithConfirmation() async throws {
    let mock = MockHTTPClient { request in
        switch request.url.path {
        case "/delete-confirm":
            return makeResponse(for: request, body: Fixtures.deleteFormPage)
        case "/xdelete":
            return makeResponse(for: request, body: "<html>ok</html>")
        default:
            return makeResponse(for: request, status: 404, body: "")
        }
    }
    let client = siteClient(mock, store: sessionStore())

    try await client.deleteItem(id: ItemID(1))

    let post = try #require(await mock.requests().first(where: { $0.url.path == "/xdelete" }))
    let body = bodyText(post)
    #expect(body.contains("fnid=fnid123"))
    #expect(body.contains("d=Yes"))
}

@Test func siteFavoritesHidesFlagsAndUnflags() async throws {
    let mock = MockHTTPClient { request in
        makeResponse(for: request, body: "<html>ok</html>")
    }
    let client = siteClient(mock, store: sessionStore())

    try await client.setFavorite(true, on: ItemID(1))
    try await client.setFavorite(false, on: ItemID(1))
    try await client.setHidden(true, on: ItemID(1))
    try await client.setHidden(false, on: ItemID(1))
    try await client.flag(itemID: ItemID(1), reason: "spam")
    try await client.unflag(itemID: ItemID(1))

    let requests = await mock.requests().filter { $0.url.path != "/news" }
    #expect(requests.map(\.url.path) == ["/fave", "/fave", "/hide", "/hide", "/flag", "/flag"])
    #expect(bodyText(requests[0]).contains("un=t") == false)
    #expect(bodyText(requests[1]).contains("un=t"))
    #expect(bodyText(requests[2]).contains("un=t") == false)
    #expect(bodyText(requests[3]).contains("un=t"))
    #expect(bodyText(requests[4]).contains("reason=spam"))
    #expect(bodyText(requests[5]).contains("un=t"))
}

@Test func siteParsesLeaders() async throws {
    let mock = MockHTTPClient { request in
        makeResponse(for: request, body: Fixtures.leadersPage)
    }
    let client = siteClient(mock)
    let leaders = try await client.leaders()
    #expect(leaders.map(\.userID.rawValue) == ["alice", "bob"])
}

@Test func siteSignsUpWithCreatingFlag() async throws {
    let store = InMemorySessionStore()
    let mock = MockHTTPClient { request in
        if request.url.path == "/login" && request.method == "POST" {
            return makeResponse(
                for: request,
                status: 302,
                headers: Fixtures.loginSuccessHeaders,
                body: ""
            )
        }
        return makeResponse(for: request, status: 404, body: "")
    }
    let client = siteClient(mock, store: store)

    let session = try await client.signUp(
        Credentials(username: "alice", password: "secret")
    )
    #expect(session.userID == UserID("alice"))

    let request = try #require(await mock.requests().first)
    #expect(bodyText(request).contains("creating=t"))
}

@Test func siteValidatesGoodSession() async throws {
    let store = sessionStore()
    let mock = MockHTTPClient { request in
        makeResponse(
            for: request,
            body: "<html><a href=\"logout?auth=abc123def456&goto=news\">logout</a></html>"
        )
    }
    let client = siteClient(mock, store: store)

    let session = try await client.validateSession()
    #expect(session?.userID == UserID("alice"))
    #expect(try store.load() != nil)
}
