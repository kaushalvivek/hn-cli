import Foundation
import HackerNewsCore

public struct ComposeContext: Equatable, Sendable {
    public var author: UserID?
    public var storyTitle: String?
    public var excerpt: String?
    public var itemID: ItemID?
    public var label: String

    public init(
        author: UserID? = nil,
        storyTitle: String? = nil,
        excerpt: String? = nil,
        itemID: ItemID?,
        label: String
    ) {
        self.author = author
        self.storyTitle = storyTitle
        self.excerpt = excerpt
        self.itemID = itemID
        self.label = label
    }
}

public enum ComposeKind: Equatable, Sendable {
    case comment(parentID: ItemID)
    case edit(itemID: ItemID)
    case submitText(title: String)

    public var draftKey: String {
        switch self {
        case .comment(let parentID): "comment:\(parentID.rawValue)"
        case .edit(let itemID): "edit:\(itemID.rawValue)"
        case .submitText(let title): "submit:\(title)"
        }
    }

    public var title: String {
        switch self {
        case .comment: "Reply"
        case .edit: "Edit"
        case .submitText: "New story"
        }
    }

    public var submitLabel: String {
        switch self {
        case .comment: "post"
        case .edit: "save"
        case .submitText: "submit"
        }
    }
}

public struct ComposeState: Equatable, Sendable {
    public var kind: ComposeKind
    public var context: ComposeContext
    public var text: String
    public var cursor: Int
    public var scroll: Int
    public var isSubmitting: Bool
    public var error: String?
    public var restoredDraft: Bool

    public init(
        kind: ComposeKind,
        context: ComposeContext,
        text: String = "",
        cursor: Int? = nil,
        scroll: Int = 0,
        isSubmitting: Bool = false,
        error: String? = nil,
        restoredDraft: Bool = false
    ) {
        self.kind = kind
        self.context = context
        self.text = text
        self.cursor = cursor ?? text.count
        self.scroll = scroll
        self.isSubmitting = isSubmitting
        self.error = error
        self.restoredDraft = restoredDraft
    }

    public var characterCount: Int { text.count }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func insert(_ value: String) {
        guard !value.isEmpty, !isSubmitting else { return }
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
        var characters = Array(text)
        let index = min(max(0, cursor), characters.count)
        characters.insert(contentsOf: Array(normalized), at: index)
        text = String(characters)
        cursor = index + normalized.count
        error = nil
    }

    public mutating func backspace() {
        guard !isSubmitting, cursor > 0 else { return }
        var characters = Array(text)
        let index = min(cursor, characters.count)
        characters.remove(at: index - 1)
        text = String(characters)
        cursor = index - 1
        error = nil
    }

    public mutating func deleteForward() {
        guard !isSubmitting else { return }
        var characters = Array(text)
        guard cursor < characters.count else { return }
        characters.remove(at: cursor)
        text = String(characters)
        error = nil
    }

    public mutating func moveLeft() {
        cursor = max(0, cursor - 1)
    }

    public mutating func moveRight() {
        cursor = min(text.count, cursor + 1)
    }

    public mutating func moveUp() {
        let characters = Array(text)
        let bounds = lineBounds(at: cursor, in: characters)
        guard bounds.start > 0 else {
            cursor = 0
            return
        }
        let previousEnd = bounds.start - 1
        let previousStart = lineStart(before: previousEnd, in: characters)
        let column = cursor - bounds.start
        cursor = previousStart + min(column, previousEnd - previousStart)
    }

    public mutating func moveDown() {
        let characters = Array(text)
        let bounds = lineBounds(at: cursor, in: characters)
        guard bounds.end < characters.count else {
            cursor = characters.count
            return
        }
        let nextStart = bounds.end + 1
        var nextEnd = nextStart
        while nextEnd < characters.count, characters[nextEnd] != "\n" {
            nextEnd += 1
        }
        let column = cursor - bounds.start
        cursor = nextStart + min(column, nextEnd - nextStart)
    }

    public mutating func moveHome() {
        let characters = Array(text)
        cursor = lineBounds(at: cursor, in: characters).start
    }

    public mutating func moveEnd() {
        let characters = Array(text)
        cursor = lineBounds(at: cursor, in: characters).end
    }

    public mutating func movePage(up: Bool, lines: Int = 6) {
        for _ in 0..<max(1, lines) {
            if up { moveUp() } else { moveDown() }
        }
    }

    private func lineBounds(at position: Int, in characters: [Character]) -> (start: Int, end: Int) {
        let position = min(max(0, position), characters.count)
        var start = position
        while start > 0, characters[start - 1] != "\n" {
            start -= 1
        }
        var end = position
        while end < characters.count, characters[end] != "\n" {
            end += 1
        }
        return (start, end)
    }

    private func lineStart(before newline: Int, in characters: [Character]) -> Int {
        var start = newline
        while start > 0, characters[start - 1] != "\n" {
            start -= 1
        }
        return start
    }
}

struct ComposeLayoutLine: Equatable {
    let text: String
    let start: Int
    let end: Int
}

struct ComposeLayout: Equatable {
    let lines: [ComposeLayoutLine]
    let cursorLine: Int
    let cursorColumn: Int
}

enum ComposeLayoutBuilder {
    static func build(text: String, width: Int) -> ComposeLayout {
        let characters = Array(text)
        let usableWidth = max(8, width)
        var lines: [ComposeLayoutLine] = []
        var lineStart = 0
        var current = ""
        var currentWidth = 0

        func appendLine(end: Int) {
            lines.append(
                ComposeLayoutLine(
                    text: current,
                    start: lineStart,
                    end: end
                )
            )
        }

        for (index, character) in characters.enumerated() {
            if character == "\n" {
                appendLine(end: index)
                current = ""
                currentWidth = 0
                lineStart = index + 1
                continue
            }

            let characterWidth = DisplayWidth.of(character)
            if currentWidth + characterWidth > usableWidth, !current.isEmpty {
                appendLine(end: index)
                current = ""
                currentWidth = 0
                lineStart = index
            }

            current.append(character)
            currentWidth += characterWidth
        }
        appendLine(end: characters.count)

        guard !lines.isEmpty else {
            return ComposeLayout(
                lines: [ComposeLayoutLine(text: "", start: 0, end: 0)],
                cursorLine: 0,
                cursorColumn: 0
            )
        }

        let cursor = min(max(0, text.count), characters.count)
        var cursorLine = lines.count - 1
        for (index, line) in lines.enumerated() {
            if cursor >= line.start, cursor <= line.end {
                cursorLine = index
                break
            }
        }

        let line = lines[cursorLine]
        let prefixEnd = min(cursor, line.end)
        let prefix = String(characters[line.start..<prefixEnd])
        let cursorColumn = DisplayWidth.of(prefix)

        return ComposeLayout(
            lines: lines,
            cursorLine: cursorLine,
            cursorColumn: cursorColumn
        )
    }
}
