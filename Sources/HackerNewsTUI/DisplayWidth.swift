import Foundation

/// Terminal cell width for Unicode grapheme clusters.
///
/// This is deliberately conservative: combining marks are zero-width, East
/// Asian wide characters and emoji are two cells, everything else is one. It is
/// enough to keep HN titles and comment text aligned in a terminal.
public enum DisplayWidth {
    public static func of(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard !scalars.isEmpty else { return 0 }

        var width = 0
        for scalar in scalars {
            let value = scalar.value
            if value == 0x200D || value == 0xFE0E || value == 0xFE0F {
                continue
            }
            if isZeroWidth(scalar) {
                continue
            }
            if isWide(scalar) {
                return 2
            }
            width = max(width, 1)
        }
        return width
    }

    public static func of(_ string: String) -> Int {
        string.reduce(0) { $0 + of($1) }
    }

    public static func truncate(
        _ string: String,
        to maxWidth: Int,
        ellipsis: String = "…"
    ) -> String {
        guard maxWidth > 0 else { return "" }
        guard of(string) > maxWidth else { return string }

        let ellipsisWidth = of(ellipsis)
        let budget = maxWidth >= ellipsisWidth ? maxWidth - ellipsisWidth : maxWidth
        var result = ""
        var used = 0
        for character in string {
            let width = of(character)
            guard used + width <= budget else { break }
            result.append(character)
            used += width
        }
        if maxWidth >= ellipsisWidth {
            result += ellipsis
        }
        return result
    }

    public static func pad(_ string: String, to width: Int, alignment: Alignment = .left) -> String {
        let fit = truncate(string, to: width)
        let padding = max(0, width - of(fit))
        switch alignment {
        case .left:
            return fit + String(repeating: " ", count: padding)
        case .right:
            return String(repeating: " ", count: padding) + fit
        case .center:
            let left = padding / 2
            return String(repeating: " ", count: left)
                + fit
                + String(repeating: " ", count: padding - left)
        }
    }

    public enum Alignment: Sendable {
        case left
        case center
        case right
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x20 || value == 0x7F {
            return true
        }
        if (0x0300...0x036F).contains(value)
            || (0x1AB0...0x1AFF).contains(value)
            || (0x1DC0...0x1DFF).contains(value)
            || (0x20D0...0x20FF).contains(value)
            || (0xFE20...0xFE2F).contains(value)
        {
            return true
        }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return true
        default:
            return false
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x1100...0x115F).contains(value)
            || (0x2329...0x232A).contains(value)
            || (0x2E80...0x303E).contains(value)
            || (0x3040...0xA4CF).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE10...0xFE19).contains(value)
            || (0xFE30...0xFE6F).contains(value)
            || (0xFF00...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value)
            || (0x1F300...0x1FAFF).contains(value)
            || (0x1F004...0x1F0CF).contains(value)
            || (0x1F18E...0x1F18E).contains(value)
            || (0x1F191...0x1F19A).contains(value)
            || (0x1F200...0x1F2FF).contains(value)
            || (0x20000...0x3FFFD).contains(value)
    }
}
