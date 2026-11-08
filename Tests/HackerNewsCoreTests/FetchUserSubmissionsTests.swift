import Testing
@testable import HackerNewsCore

@Test func userSubmissionsPreserveOrderAndPaginate() async throws {
    let user = User(
        id: UserID("alice"),
        createdAt: Fixture.date,
        karma: 100,
        submittedItemIDs: [ItemID(1), ItemID(2), ItemID(3)]
    )
    let fetch = FetchUserSubmissions(
        users: StubUserProvider(users: [UserID("alice"): user]),
        items: StubItemProvider(items: [
            ItemID(1): Fixture.story(1),
            ItemID(2): Fixture.story(2),
            ItemID(3): Fixture.story(3),
        ])
    )

    let page = try await fetch(
        userID: UserID("alice"),
        page: try PageRequest(offset: 1, limit: 1)
    )

    #expect(page.items.map(\.id) == [ItemID(2)])
    #expect(page.offset == 1)
    #expect(page.hasMore)
    #expect(page.totalCount == 3)
}

@Test func userSubmissionsThrowForUnknownUser() async throws {
    let fetch = FetchUserSubmissions(
        users: StubUserProvider(users: [:]),
        items: StubItemProvider(items: [:])
    )

    do {
        _ = try await fetch(userID: UserID("ghost"))
        Issue.record("Expected notFound")
    } catch let error as HackerNewsError {
        #expect(error == .notFound(.user(UserID("ghost"))))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
