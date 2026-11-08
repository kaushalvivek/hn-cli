import Foundation

enum TUIText {
    static func wrap(_ text: String, width: Int) -> [String] {
        let usable = max(10, width)
        var result: [String] = []

        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if paragraph.isEmpty {
                result.append("")
                continue
            }

            var line = ""
            var lineWidth = 0
            for wordSub in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                let word = String(wordSub)
                let wordWidth = DisplayWidth.of(word)
                let spaceWidth = line.isEmpty ? 0 : 1

                if lineWidth + spaceWidth + wordWidth <= usable {
                    if !line.isEmpty {
                        line += " "
                        lineWidth += 1
                    }
                    line += word
                    lineWidth += wordWidth
                } else {
                    if !line.isEmpty {
                        result.append(line)
                    }
                    if wordWidth <= usable {
                        line = word
                        lineWidth = wordWidth
                    } else {
                        // Break a long token rather than overflowing the pane.
                        var chunk = ""
                        var chunkWidth = 0
                        for character in word {
                            let characterWidth = DisplayWidth.of(character)
                            if chunkWidth + characterWidth > usable, !chunk.isEmpty {
                                result.append(chunk)
                                chunk = ""
                                chunkWidth = 0
                            }
                            chunk.append(character)
                            chunkWidth += characterWidth
                        }
                        line = chunk
                        lineWidth = chunkWidth
                    }
                }
            }
            if !line.isEmpty {
                result.append(line)
            }
        }

        return result
    }

    static func truncate(_ text: String, width: Int) -> String {
        DisplayWidth.truncate(text, to: width)
    }

    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "\(Int(seconds))s"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<2_592_000: return "\(Int(seconds / 86_400))d"
        case ..<31_536_000: return "\(Int(seconds / 2_592_000))mo"
        default: return "\(Int(seconds / 31_536_000))y"
        }
    }
}

extension StyledText {
    func restyled(_ style: Style) -> StyledText {
        StyledText(spans: spans.map { Span($0.text, style: style) })
    }
}
