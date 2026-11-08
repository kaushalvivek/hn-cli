import Foundation
import Testing
import HackerNewsCore
@testable import HackerNewsAdapters

private let storyJSON = """
{
  "by": "dhouston",
  "descendants": 71,
  "id": 8863,
  "kids": [8952, 9224],
  "score": 104,
  "time": 1175714200,
  "title": "My YC app: Dropbox",
  "type": "story",
  "url": "http://www.getdropbox.com/u/2/screencast.html"
}
"""

private let commentJSON = """
{
  "by": "norvig",
  "id": 2921983,
  "kids": [2922097],
  "parent": 2921506,
  "text": "Aw shucks, guys ... <p>Thanks!",
  "time": 1314211127,
  "type": "comment"
}
"""

private let deletedJSON = """
{
  "deleted": true,
  "id": 50411411,
  "parent": 50411181,
  "time": 1794126475,
  "type": "comment"
}
"""

private let userJSON = """
{
  "about": "This is a test",
  "created": 1173923446,
  "id": "jl",
  "karma": 4522,
  "submitted": [44074017, 35686379]
}
"""

@Test func firebaseMapsStoryAndComment() async throws {
    let mock = MockHTTPClient { request in
        switch request.url.path {
        case "/v0/item/8863.json":
            return makeResponse(for: request, body: storyJSON)
        case "/v0/item/2921983.json":
            return makeResponse(for: request, body: commentJSON)
        case "/v0/item/50411411.json":
            return makeResponse(for: request, body: deletedJSON)
        default:
            return makeResponse(for: request, status: 404, body: "")
        }
    }
    let client = FirebaseClient(http: mock)

    let story = try #require(try await client.item(id: ItemID(8863)))
    #expect(story.kind == .story)
    #expect(story.author == UserID("dhouston"))
    #expect(story.score == 104)
    #expect(story.commentCount == 71)
    #expect(story.childIDs == [ItemID(8952), ItemID(9224)])
    #expect(story.title?.rawHTML == "My YC app: Dropbox")
    #expect(story.createdAt == Date(timeIntervalSince1970: 1_175_714_200))

    let comment = try #require(try await client.item(id: ItemID(2921983)))
    #expect(comment.kind == .comment)
    #expect(comment.text?.rawHTML == "Aw shucks, guys ... <p>Thanks!")
    #expect(comment.childIDs == [ItemID(2922097)])

    let deleted = try #require(try await client.item(id: ItemID(50411411)))
    #expect(deleted.kind == nil)
    #expect(deleted.isDeleted)
    #expect(deleted.content == .deleted(DeletedItem(parentID: ItemID(50411181), childIDs: [])))
}

@Test func firebaseMapsUser() async throws {
    let mock = MockHTTPClient { request in
        makeResponse(for: request, body: userJSON)
    }
    let client = FirebaseClient(http: mock)
    let user = try #require(try await client.user(id: UserID("jl")))
    #expect(user.karma == 4522)
    #expect(user.about?.rawHTML == "This is a test")
    #expect(user.submittedItemIDs == [ItemID(44074017), ItemID(35686379)])
}

@Test func firebaseMapsFeedsUpdatesAndMaxItem() async throws {
    let mock = MockHTTPClient { request in
        switch request.url.path {
        case "/v0/topstories.json":
            return makeResponse(for: request, body: "[1, 2, 3]")
        case "/v0/updates.json":
            return makeResponse(for: request, body: #"{"items":[4,5],"profiles":["alice","bob"]}"#)
        case "/v0/maxitem.json":
            return makeResponse(for: request, body: "999")
        default:
            return makeResponse(for: request, status: 404, body: "")
        }
    }
    let client = FirebaseClient(http: mock)

    let ids = try await client.itemIDs(forFirebaseFeed: .frontPage)
    #expect(ids == [ItemID(1), ItemID(2), ItemID(3)])

    let updates = try await client.updates()
    #expect(updates.itemIDs == [ItemID(4), ItemID(5)])
    #expect(updates.profileIDs == [UserID("alice"), UserID("bob")])

    #expect(try await client.maxItemID() == ItemID(999))
}

@Test func firebaseReturnsNilForMissingItem() async throws {
    let mock = MockHTTPClient { request in
        makeResponse(for: request, body: "null")
    }
    let client = FirebaseClient(http: mock)
    #expect(try await client.item(id: ItemID(1)) == nil)
}
