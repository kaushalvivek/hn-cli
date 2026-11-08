import Foundation

public enum Color: Equatable, Sendable {
    case terminalDefault
    case ansi(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct Style: Equatable, Sendable {
    public var fg: Color
    public var bg: Color
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool
    public var reverse: Bool

    public init(
        fg: Color = .terminalDefault,
        bg: Color = .terminalDefault,
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        reverse: Bool = false
    ) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.reverse = reverse
    }

    public static let plain = Style()

    public var ansiSequence: String {
        var codes: [String] = ["0"]
        switch fg {
        case .terminalDefault:
            break
        case .ansi(let value):
            codes.append("38;5;\(value)")
        case .rgb(let red, let green, let blue):
            codes.append("38;2;\(red);\(green);\(blue)")
        }
        switch bg {
        case .terminalDefault:
            break
        case .ansi(let value):
            codes.append("48;5;\(value)")
        case .rgb(let red, let green, let blue):
            codes.append("48;2;\(red);\(green);\(blue)")
        }
        if bold { codes.append("1") }
        if dim { codes.append("2") }
        if italic { codes.append("3") }
        if underline { codes.append("4") }
        if reverse { codes.append("7") }
        return "\u{001B}[" + codes.joined(separator: ";") + "m"
    }
}

public struct Cell: Equatable, Sendable {
    public var text: String
    public var style: Style
    public var isContinuation: Bool

    public init(text: String = " ", style: Style = .plain, isContinuation: Bool = false) {
        self.text = text
        self.style = style
        self.isContinuation = isContinuation
    }
}

public struct Rect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(x px: Int, y py: Int) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    public func inset(by amount: Int) -> Rect {
        Rect(
            x: x + amount,
            y: y + amount,
            width: width - amount * 2,
            height: height - amount * 2
        )
    }
}

public struct StyledText: Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        public var text: String
        public var style: Style

        public init(_ text: String, style: Style = .plain) {
            self.text = text
            self.style = style
        }
    }

    public var spans: [Span]

    public init(_ text: String = "", style: Style = .plain) {
        self.spans = text.isEmpty ? [] : [Span(text, style: style)]
    }

    public init(spans: [Span]) {
        self.spans = spans
    }

    public var plainText: String {
        spans.map(\.text).joined()
    }

    public var width: Int {
        DisplayWidth.of(plainText)
    }

    public mutating func append(_ text: String, style: Style = .plain) {
        guard !text.isEmpty else { return }
        spans.append(Span(text, style: style))
    }

    public mutating func append(_ other: StyledText) {
        spans.append(contentsOf: other.spans)
    }

    public func truncated(to maxWidth: Int) -> StyledText {
        guard width > maxWidth else { return self }
        var result = StyledText()
        var used = 0
        let ellipsis = "…"
        let ellipsisWidth = DisplayWidth.of(ellipsis)
        let budget = maxWidth >= ellipsisWidth ? maxWidth - ellipsisWidth : maxWidth
        var lastStyle = spans.last?.style ?? .plain

        for span in spans {
            lastStyle = span.style
            var text = ""
            for character in span.text {
                let width = DisplayWidth.of(character)
                guard used + width <= budget else { break }
                text.append(character)
                used += width
            }
            if !text.isEmpty {
                result.append(text, style: span.style)
            }
            if used >= budget { break }
        }

        if maxWidth >= ellipsisWidth {
            result.append(ellipsis, style: lastStyle)
        }
        return result
    }
}

public final class Screen {
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var cells: [Cell]

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.cells = Array(repeating: Cell(), count: self.width * self.height)
    }

    public func resize(width newWidth: Int, height newHeight: Int) {
        let newWidth = max(1, newWidth)
        let newHeight = max(1, newHeight)
        guard newWidth != width || newHeight != height else { return }

        var newCells = Array(repeating: Cell(), count: newWidth * newHeight)
        let copyWidth = min(width, newWidth)
        let copyHeight = min(height, newHeight)
        for y in 0..<copyHeight {
            for x in 0..<copyWidth {
                newCells[y * newWidth + x] = cells[y * width + x]
            }
        }
        width = newWidth
        height = newHeight
        cells = newCells
    }

    public func clear(style: Style = .plain) {
        cells = Array(repeating: Cell(style: style), count: width * height)
    }

    public func setCell(_ cell: Cell, x: Int, y: Int) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let index = y * width + x

        // If we are overwriting the tail of a wide character, remove its base.
        if cells[index].isContinuation, x > 0 {
            cells[y * width + x - 1] = Cell()
        }
        // If we are overwriting a wide character, clear its continuation.
        if x + 1 < width, cells[index + 1].isContinuation {
            cells[index + 1] = Cell()
        }

        cells[index] = cell
    }

    @discardableResult
    public func put(
        _ text: String,
        x: Int,
        y: Int,
        style: Style = .plain,
        maxWidth: Int? = nil
    ) -> Int {
        guard y >= 0, y < height, x < width else { return 0 }
        let startX = max(0, x)
        let limit = min(width, startX + (maxWidth ?? (width - startX)))
        var cursor = startX

        for character in text {
            if character == "\n" { break }
            if character == "\t" {
                let spaces = 4 - (cursor % 4)
                cursor += put(String(repeating: " ", count: spaces), x: cursor, y: y, style: style, maxWidth: limit - cursor)
                continue
            }

            let charWidth = DisplayWidth.of(character)
            if charWidth == 0 {
                var previous = cursor - 1
                if previous >= 0, cells[y * width + previous].isContinuation {
                    previous -= 1
                }
                if previous >= 0, previous < width, !cells[y * width + previous].isContinuation {
                    cells[y * width + previous].text.append(character)
                }
                continue
            }

            guard cursor + charWidth <= limit else { break }
            setCell(Cell(text: String(character), style: style), x: cursor, y: y)
            if charWidth == 2 {
                setCell(Cell(text: "", style: style, isContinuation: true), x: cursor + 1, y: y)
            }
            cursor += charWidth
        }

        return cursor - startX
    }

    @discardableResult
    public func put(
        _ text: StyledText,
        x: Int,
        y: Int,
        maxWidth: Int? = nil
    ) -> Int {
        guard y >= 0, y < height else { return 0 }
        var cursor = x
        let limit = min(width, x + (maxWidth ?? (width - x)))

        for span in text.spans {
            guard cursor < limit else { break }
            let used = put(span.text, x: cursor, y: y, style: span.style, maxWidth: limit - cursor)
            cursor += used
        }
        return cursor - x
    }

    public func fill(_ rect: Rect, style: Style, character: Character = " ") {
        guard !rect.isEmpty else { return }
        for y in max(0, rect.y)..<min(height, rect.maxY) {
            for x in max(0, rect.x)..<min(width, rect.maxX) {
                setCell(Cell(text: String(character), style: style), x: x, y: y)
            }
        }
    }

    public func drawBox(_ rect: Rect, style: Style = .plain) {
        guard rect.width >= 2, rect.height >= 2 else { return }
        put("┌" + String(repeating: "─", count: rect.width - 2) + "┐", x: rect.x, y: rect.y, style: style)
        put("└" + String(repeating: "─", count: rect.width - 2) + "┘", x: rect.x, y: rect.maxY - 1, style: style)
        for y in (rect.y + 1)..<(rect.maxY - 1) {
            put("│", x: rect.x, y: y, style: style)
            put("│", x: rect.maxX - 1, y: y, style: style)
        }
    }

    public func hline(x: Int, y: Int, width: Int, style: Style = .plain) {
        guard width > 0 else { return }
        put(String(repeating: "─", count: width), x: x, y: y, style: style)
    }

    public func vline(x: Int, y: Int, height: Int, style: Style = .plain) {
        guard height > 0 else { return }
        for row in y..<(y + height) {
            put("│", x: x, y: row, style: style)
        }
    }

    /// Renders the screen with synchronized output. A full repaint is used to
    /// keep wide-character and wrapping behavior deterministic; the terminal's
    /// synchronized-output mode prevents tearing.
    public func render() -> String {
        var output = "\u{001B}[?2026h\u{001B}[H"

        for y in 0..<height {
            output += "\u{001B}[\(y + 1);1H"

            var lastCell = width - 1
            while lastCell >= 0 {
                let cell = cells[y * width + lastCell]
                if cell.text != " " || cell.style != .plain || cell.isContinuation {
                    break
                }
                lastCell -= 1
            }

            guard lastCell >= 0 else {
                output += "\u{001B}[K"
                continue
            }

            var currentStyle = Style.plain
            for x in 0...lastCell {
                let cell = cells[y * width + x]
                if cell.isContinuation { continue }
                if cell.style != currentStyle {
                    output += cell.style.ansiSequence
                    currentStyle = cell.style
                }
                output += cell.text
            }
            output += "\u{001B}[0m\u{001B}[K"
        }

        output += "\u{001B}[0m\u{001B}[?2026l"
        return output
    }

    public func plainText() -> String {
        var lines: [String] = []
        for y in 0..<height {
            var line = ""
            for x in 0..<width {
                let cell = cells[y * width + x]
                if cell.isContinuation { continue }
                line += cell.text
            }
            lines.append(line.trimmingCharacters(in: CharacterSet(charactersIn: " ")))
        }
        return lines.joined(separator: "\n")
    }
}
