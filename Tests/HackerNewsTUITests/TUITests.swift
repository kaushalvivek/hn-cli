import Foundation
import Testing
import HackerNewsCore
import HackerNewsAdapters
@testable import HackerNewsTUI

@Test func displayWidthHandlesWideAndCombiningCharacters() {
    #expect(DisplayWidth.of("a") == 1)
    #expect(DisplayWidth.of("漢") == 2)
    #expect(DisplayWidth.of("👋") == 2)
    #expect(DisplayWidth.of("e\u{0301}") == 1)
    #expect(DisplayWidth.of("漢a") == 3)
}

@Test func displayWidthTruncatesAtCellBoundaries() {
    #expect(DisplayWidth.truncate("abcdef", to: 4) == "abc…")
    #expect(DisplayWidth.truncate("漢字", to: 3) == "漢…")
    #expect(DisplayWidth.truncate("abc", to: 3) == "abc")
}

@Test func screenRendersWideCharactersAndStyles() {
    let screen = Screen(width: 10, height: 2)
    screen.put("漢a", x: 0, y: 0, style: Theme.accent)
    screen.put("b", x: 3, y: 0)
    let text = screen.plainText()
    #expect(text.contains("漢ab"))
}

@Test func screenDrawsBox() {
    let screen = Screen(width: 8, height: 4)
    screen.drawBox(Rect(x: 0, y: 0, width: 6, height: 3), style: Theme.border)
    let text = screen.plainText()
    #expect(text.contains("┌────┐"))
    #expect(text.contains("└────┘"))
}

@Test func inputParserParsesArrowsControlsAndUTF8() {
    var parser = InputParser()
    #expect(parser.feed(Data([0x1B, 0x5B, 0x41])) == [.up])
    #expect(parser.feed(Data([0x1B, 0x5B, 0x42])) == [.down])
    #expect(parser.feed(Data([0x10])) == [.ctrl("p")])
    #expect(parser.feed(Data([0x03])) == [.ctrl("c")])
    #expect(parser.feed(Data("é".utf8)) == [.character("é")])
}

@Test func inputParserWaitsForSplitUTF8() {
    var parser = InputParser()
    let bytes = Array("é".utf8)
    #expect(parser.feed(Data([bytes[0]])) == [])
    #expect(parser.feed(Data([bytes[1]])) == [.character("é")])
}

@Test func inputParserParsesPasteAndMouse() {
    var parser = InputParser()
    #expect(parser.feed(Data("\u{001B}[200~hello\u{001B}[201~".utf8)) == [.paste("hello")])

    let mouse = parser.feed(Data("\u{001B}[<0;10;5M".utf8))
    #expect(mouse == [
        .mouse(
            MouseEvent(
                x: 9,
                y: 4,
                button: .left,
                action: .press
            )
        )
    ])
}

@Test func inputParserFlushesLoneEscape() {
    var parser = InputParser()
    #expect(parser.feed(Data([0x1B])) == [])
    #expect(parser.hasPendingEscape)
    #expect(parser.flushPendingEscape() == [.escape])
}

@MainActor
@Test func previewRendersStoryMetadata() {
    let state = BrowserState(client: HackerNewsClient())
    let hit = SearchHit(
        id: ItemID(1),
        kind: .story,
        author: UserID("alice"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        title: HTMLText("Drop Dropbox"),
        url: URL(string: "https://drop-dropbox.com/"),
        score: 1990,
        commentCount: 1008
    )
    state.detail = .preview(TUIEntry(hit: hit))

    let screen = Screen(width: 120, height: 40)
    BrowserView.render(state, into: screen)
    let text = screen.plainText()

    #expect(text.contains("Drop Dropbox"))
    #expect(text.contains("1990 points"))
    #expect(text.contains("1008 comments"))
    #expect(text.contains("drop-dropbox.com"))
}

@MainActor
@Test func helpOverlayRenders() {
    let state = BrowserState(client: HackerNewsClient())
    state.overlay = .help
    let screen = Screen(width: 120, height: 40)
    BrowserView.render(state, into: screen)
    let text = screen.plainText()
    #expect(text.contains("Keyboard"))
    #expect(text.contains("move"))
    #expect(text.contains("quit"))
}

@MainActor
@Test func threadStartsWithCollapsedReplies() {
    let comment = Item(
        id: ItemID(2),
        author: UserID("alice"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        content: .comment(
            Comment(
                parentID: ItemID(1),
                text: HTMLText("hello"),
                childIDs: [ItemID(3)]
            )
        )
    )
    let root = Item(
        id: ItemID(1),
        author: UserID("bob"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        content: .story(
            Story(
                title: HTMLText("A story"),
                score: 10,
                commentCount: 1,
                commentIDs: [ItemID(2)]
            )
        )
    )

    let node = TUICommentNode(item: comment, replies: nil)
    let thread = TUIThread(root: root, topLevel: [node])
    #expect(thread.visible.count == 1)
    #expect(thread.visible[0].node.id == ItemID(2))
    #expect(thread.visible[0].depth == 0)

    node.isExpanded = true
    node.replies = []
    thread.rebuild()
    #expect(thread.visible.count == 1)
}
