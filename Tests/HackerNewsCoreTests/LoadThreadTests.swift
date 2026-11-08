import Testing
@testable import HackerNewsCore

private func makeProvider() -> StubItemProvider {
    StubItemProvider(items: [
        ItemID(1): Fixture.story(1, kids: [2, 3]),
        ItemID(2): Fixture.comment(2, parent: 1, kids: [4]),
        ItemID(3): Fixture.deleted(3, parent: 1, kids: [5]),
        ItemID(4): Fixture.comment(4, parent: 2, dead: true),
        ItemID(5): Fixture.comment(5, parent: 3),
    ])
}

@Test func threadLoadsFullTreeInOrder() async throws {
    let thread = try await LoadThread(items: makeProvider())(rootID: ItemID(1))

    #expect(thread.root.id == ItemID(1))
    #expect(thread.replies.map(\.id) == [ItemID(2), ItemID(3)])
    #expect(thread.replies[0].replies.map(\.id) == [ItemID(4)])
    #expect(thread.replies[0].replies[0].item.isDead)
    #expect(thread.replies[1].item.isDeleted)
    #expect(thread.replies[1].replies.map(\.id) == [ItemID(5)])
    #expect(thread.loadedItemCount == 5)
    #expect(thread.missingItemCount == 0)
    #expect(thread.isComplete)
}

@Test func threadLoadsFromACommentRoot() async throws {
    let thread = try await LoadThread(items: makeProvider())(rootID: ItemID(2))

    #expect(thread.root.id == ItemID(2))
    #expect(thread.replies.map(\.id) == [ItemID(4)])
    #expect(thread.loadedItemCount == 2)
    #expect(thread.isComplete)
}

@Test func threadRecordsMissingChildren() async throws {
    let provider = StubItemProvider(items: [
        ItemID(1): Fixture.story(1, kids: [2, 99]),
        ItemID(2): Fixture.comment(2, parent: 1),
    ])

    let thread = try await LoadThread(items: provider)(rootID: ItemID(1))

    #expect(thread.replies.map(\.id) == [ItemID(2)])
    #expect(thread.loadedItemCount == 2)
    #expect(thread.missingItemCount == 1)
    #expect(thread.isComplete == false)
}

@Test func threadRespectsMaxDepth() async throws {
    let thread = try await LoadThread(items: makeProvider())(
        rootID: ItemID(1),
        policy: ThreadLoadPolicy(maxDepth: 1)
    )

    #expect(thread.replies.map(\.id) == [ItemID(2), ItemID(3)])
    #expect(thread.replies[0].replies.isEmpty)
    #expect(thread.replies[1].replies.isEmpty)
    #expect(thread.loadedItemCount == 3)
    #expect(thread.isComplete == false)
}

@Test func threadWithMaxDepthZeroLoadsOnlyTheRoot() async throws {
    let thread = try await LoadThread(items: makeProvider())(
        rootID: ItemID(1),
        policy: ThreadLoadPolicy(maxDepth: 0)
    )

    #expect(thread.replies.isEmpty)
    #expect(thread.loadedItemCount == 1)
    #expect(thread.isComplete == false)
}

@Test func threadRespectsMaxNodes() async throws {
    let thread = try await LoadThread(items: makeProvider())(
        rootID: ItemID(1),
        policy: ThreadLoadPolicy(maxNodes: 2)
    )

    #expect(thread.loadedItemCount == 2)
    #expect(thread.replies.map(\.id) == [ItemID(2)])
    #expect(thread.isComplete == false)
}

@Test func threadWithNoCommentsIsComplete() async throws {
    let provider = StubItemProvider(items: [
        ItemID(1): Fixture.story(1, kids: []),
    ])

    let thread = try await LoadThread(items: provider)(rootID: ItemID(1))

    #expect(thread.replies.isEmpty)
    #expect(thread.loadedItemCount == 1)
    #expect(thread.isComplete)
}

@Test func threadThrowsWhenRootIsMissing() async throws {
    let provider = StubItemProvider(items: [:])
    let load = LoadThread(items: provider)

    do {
        _ = try await load(rootID: ItemID(999))
        Issue.record("Expected notFound")
    } catch let error as HackerNewsError {
        #expect(error == .notFound(.item(ItemID(999))))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
