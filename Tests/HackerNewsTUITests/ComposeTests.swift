import Foundation
import Testing
import HackerNewsCore
import HackerNewsAdapters
@testable import HackerNewsTUI

@Test func composeStateEditsAndNavigates() {
    var compose = ComposeState(
        kind: .comment(parentID: ItemID(1)),
        context: ComposeContext(itemID: ItemID(1), label: "Replying to")
    )

    compose.insert("hello")
    #expect(compose.text == "hello")
    #expect(compose.cursor == 5)

    compose.insert("\nworld")
    #expect(compose.text == "hello\nworld")
    #expect(compose.cursor == 11)

    compose.moveUp()
    #expect(compose.cursor == 5)
    compose.moveHome()
    #expect(compose.cursor == 0)
    compose.moveEnd()
    #expect(compose.cursor == 5)
    compose.moveDown()
    #expect(compose.cursor == 11)

    compose.backspace()
    #expect(compose.text == "hello\nworl")
    compose.deleteForward()
    #expect(compose.text == "hello\nworl")
}

@Test func composeLayoutWrapsAndTracksCursor() {
    let text = "one two three"
    let layout = ComposeLayoutBuilder.build(text: text, width: 7)
    #expect(layout.lines.count >= 2)
    #expect(layout.lines.map(\.text).joined() == text)
    #expect(layout.cursorLine == layout.lines.count - 1)
    #expect(layout.cursorColumn == DisplayWidth.of(layout.lines.last?.text ?? ""))
}

@Test func composeDraftStoreRoundTripsPrivately() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hn-draft-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("drafts.json")
    let store = ComposeDraftStore(url: url)
    let record = ComposeDraftRecord(
        text: "half-written reply",
        savedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(try store.load().isEmpty)
    try store.save(["comment:1": record])
    let loaded = try #require(try store.load()["comment:1"])
    #expect(loaded.text == "half-written reply")
    #expect(loaded.savedAt == Date(timeIntervalSince1970: 1_700_000_000))

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue == 0o600)

    try store.save([:])
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@MainActor
@Test func threadInsertsAndSelectsNewComment() {
    let root = Item(
        id: ItemID(1),
        author: UserID("alice"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        content: .story(
            Story(
                title: HTMLText("Story"),
                commentCount: 1,
                commentIDs: [ItemID(2)]
            )
        )
    )
    let parent = Item(
        id: ItemID(2),
        author: UserID("bob"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        content: .comment(
            Comment(parentID: ItemID(1), text: HTMLText("parent"), childIDs: [])
        )
    )
    let reply = Item(
        id: ItemID(3),
        author: UserID("alice"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_100),
        content: .comment(
            Comment(parentID: ItemID(2), text: HTMLText("new reply"), childIDs: [])
        )
    )

    let thread = TUIThread(
        root: root,
        topLevel: [TUICommentNode(item: parent, replies: [])]
    )
    #expect(thread.visible.count == 1)
    #expect(thread.insert(reply, under: ItemID(2)))
    #expect(thread.visible.count == 2)
    #expect(thread.visible[1].node.id == ItemID(3))
    #expect(thread.selectedIndex == 1)
}

@MainActor
@Test func composeOverlayRendersContextAndDraft() {
    let state = BrowserState(client: HackerNewsClient())
    state.overlay = .compose(
        ComposeState(
            kind: .comment(parentID: ItemID(1)),
            context: ComposeContext(
                author: UserID("alice"),
                storyTitle: "A story",
                excerpt: "The parent comment",
                itemID: ItemID(1),
                label: "Replying to"
            ),
            text: "This is my reply",
            restoredDraft: true
        )
    )

    let screen = Screen(width: 120, height: 40)
    BrowserView.render(state, into: screen)
    let text = screen.plainText()

    #expect(text.contains("Reply"))
    #expect(text.contains("Replying to"))
    #expect(text.contains("alice"))
    #expect(text.contains("A story"))
    #expect(text.contains("This is my reply"))
    #expect(text.contains("ctrl-s post"))
}
