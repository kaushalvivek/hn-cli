import Foundation

public enum KeyEvent: Equatable, Sendable {
    case character(Character)
    case enter
    case tab
    case backTab
    case escape
    case backspace
    case delete
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case ctrl(Character)
    case function(Int)
    case paste(String)
    case mouse(MouseEvent)
    case unknown(String)
}

public enum MouseButton: Equatable, Sendable {
    case left
    case middle
    case right
    case none
}

public enum MouseAction: Equatable, Sendable {
    case press
    case release
    case drag
    case scrollUp
    case scrollDown
}

public struct MouseEvent: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let button: MouseButton
    public let action: MouseAction
    public let shift: Bool
    public let alt: Bool
    public let ctrl: Bool

    public init(
        x: Int,
        y: Int,
        button: MouseButton,
        action: MouseAction,
        shift: Bool = false,
        alt: Bool = false,
        ctrl: Bool = false
    ) {
        self.x = x
        self.y = y
        self.button = button
        self.action = action
        self.shift = shift
        self.alt = alt
        self.ctrl = ctrl
    }
}

/// Incremental parser for terminal input. Feed it bytes as they arrive and it
/// returns complete key events.
public struct InputParser {
    private var buffer: [UInt8] = []
    private var pasteBuffer: [UInt8] = []
    private var inPaste = false

    private static let pasteStart: [UInt8] = Array("\u{001B}[200~".utf8)
    private static let pasteEnd: [UInt8] = Array("\u{001B}[201~".utf8)

    public init() {}

    public var hasPendingEscape: Bool {
        buffer == [0x1B]
    }

    public mutating func flushPendingEscape() -> [KeyEvent] {
        guard hasPendingEscape else { return [] }
        buffer.removeAll(keepingCapacity: true)
        return [.escape]
    }

    public mutating func feed(_ data: Data) -> [KeyEvent] {
        buffer.append(contentsOf: data)
        var events: [KeyEvent] = []

        parseLoop: while true {
            if inPaste {
                if let range = Self.find(Self.pasteEnd, in: buffer) {
                    pasteBuffer.append(contentsOf: buffer[..<range.lowerBound])
                    buffer.removeFirst(range.upperBound)
                    inPaste = false
                    let text = String(decoding: pasteBuffer, as: UTF8.self)
                    pasteBuffer.removeAll(keepingCapacity: true)
                    events.append(.paste(text))
                    continue
                }
                // Wait for the rest of the paste. Bracket paste payloads can be
                // large, but they are bounded by the user's clipboard.
                break
            }

            guard let first = buffer.first else { break }

            if first == 0x1B {
                if buffer.count == 1 {
                    break
                }
                let second = buffer[1]
                if second == 0x5B || second == 0x4F {
                    guard let finalIndex = Self.csiFinalIndex(in: buffer) else {
                        break
                    }
                    let sequence = Array(buffer[0...finalIndex])
                    buffer.removeFirst(finalIndex + 1)

                    if sequence == Self.pasteStart {
                        pasteBuffer.removeAll(keepingCapacity: true)
                        inPaste = true
                        continue
                    }
                    if sequence == Self.pasteEnd {
                        continue
                    }

                    if let event = Self.parseEscapeSequence(sequence) {
                        events.append(event)
                    }
                    continue
                }

                // ESC followed by a normal key: emit Escape, then let the next
                // loop iteration process the key.
                buffer.removeFirst()
                events.append(.escape)
                continue
            }

            switch first {
            case 0x0D, 0x0A:
                buffer.removeFirst()
                events.append(.enter)
            case 0x09:
                buffer.removeFirst()
                events.append(.tab)
            case 0x7F, 0x08:
                buffer.removeFirst()
                events.append(.backspace)
            case 0x03:
                buffer.removeFirst()
                events.append(.ctrl("c"))
            case 0x00:
                buffer.removeFirst()
                events.append(.ctrl(" "))
            case 0x01...0x1A:
                buffer.removeFirst()
                let scalar = Unicode.Scalar(Int(first) + 0x60)!
                events.append(.ctrl(Character(scalar)))
            case 0x1C...0x1F:
                buffer.removeFirst()
                let scalar = Unicode.Scalar(Int(first) + 0x40)!
                events.append(.ctrl(Character(scalar)))
            default:
                let length = Self.utf8Length(first)
                guard buffer.count >= length else { break parseLoop }
                let bytes = Array(buffer[0..<length])
                buffer.removeFirst(length)
                let string = String(decoding: bytes, as: UTF8.self)
                if string.isEmpty {
                    events.append(.unknown(String(decoding: bytes, as: UTF8.self)))
                } else {
                    for character in string {
                        events.append(.character(character))
                    }
                }
            }
        }

        return events
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for index in 0...(haystack.count - needle.count) {
            if Array(haystack[index..<(index + needle.count)]) == needle {
                return index..<(index + needle.count)
            }
        }
        return nil
    }

    private static func csiFinalIndex(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 3 else { return nil }
        var index = 2
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 0x40 && byte <= 0x7E {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func parseEscapeSequence(_ bytes: [UInt8]) -> KeyEvent? {
        guard bytes.count >= 3 else { return nil }
        let final = bytes.last!
        let body = String(decoding: bytes[2..<(bytes.count - 1)], as: UTF8.self)

        if bytes[1] == 0x4F {
            switch final {
            case 0x50: return .function(1)
            case 0x51: return .function(2)
            case 0x52: return .function(3)
            case 0x53: return .function(4)
            case 0x41: return .up
            case 0x42: return .down
            case 0x43: return .right
            case 0x44: return .left
            case 0x48: return .home
            case 0x46: return .end
            default: return .unknown(String(decoding: bytes, as: UTF8.self))
            }
        }

        if body.hasPrefix("<"), final == 0x4D || final == 0x6D {
            if let event = parseMouse(body: body, release: final == 0x6D) {
                return .mouse(event)
            }
            return nil
        }

        switch final {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x48: return .home
        case 0x46: return .end
        case 0x5A: return .backTab
        case 0x50...0x53: return .function(Int(final - 0x50) + 1)
        case 0x7E:
            let parameter = Int(body.split(separator: ";").first ?? "") ?? 0
            switch parameter {
            case 1, 7: return .home
            case 2: return .home
            case 3: return .delete
            case 4, 8: return .end
            case 5: return .pageUp
            case 6: return .pageDown
            case 11: return .function(1)
            case 12: return .function(2)
            case 13: return .function(3)
            case 14: return .function(4)
            case 15: return .function(5)
            case 17: return .function(6)
            case 18: return .function(7)
            case 19: return .function(8)
            case 20: return .function(9)
            case 21: return .function(10)
            case 23: return .function(11)
            case 24: return .function(12)
            default:
                return .unknown(String(decoding: bytes, as: UTF8.self))
            }
        default:
            return .unknown(String(decoding: bytes, as: UTF8.self))
        }
    }

    private static func parseMouse(body: String, release: Bool) -> MouseEvent? {
        let parts = body.dropFirst().split(separator: ";")
        guard parts.count >= 3,
              let code = Int(parts[0]),
              let x = Int(parts[1]),
              let y = Int(parts[2])
        else {
            return nil
        }

        let buttonBits = code & 0b11
        let shift = (code & 4) != 0
        let alt = (code & 8) != 0
        let ctrl = (code & 16) != 0
        let motion = (code & 32) != 0
        let wheel = (code & 64) != 0

        if wheel {
            let action: MouseAction = (buttonBits == 0) ? .scrollUp : .scrollDown
            return MouseEvent(
                x: x - 1,
                y: y - 1,
                button: .none,
                action: action,
                shift: shift,
                alt: alt,
                ctrl: ctrl
            )
        }

        let button: MouseButton
        switch buttonBits {
        case 0: button = .left
        case 1: button = .middle
        case 2: button = .right
        default: button = .none
        }

        let action: MouseAction
        if release {
            action = .release
        } else if motion {
            action = .drag
        } else {
            action = .press
        }

        return MouseEvent(
            x: x - 1,
            y: y - 1,
            button: button,
            action: action,
            shift: shift,
            alt: alt,
            ctrl: ctrl
        )
    }

    private static func utf8Length(_ first: UInt8) -> Int {
        switch first {
        case 0x00...0x7F: 1
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: 1
        }
    }
}

extension KeyEvent {
    public var characterValue: Character? {
        if case .character(let character) = self { return character }
        return nil
    }
}
