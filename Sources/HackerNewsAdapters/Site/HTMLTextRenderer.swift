import Foundation
import SwiftSoup

public enum HTMLTextRenderer {
    /// Renders Hacker News' HTML text as readable terminal text.
    public static func plainText(_ html: String) -> String {
        guard let document = try? SwiftSoup.parseBodyFragment(html),
              let body = document.body()
        else {
            return html
        }

        var output = ""
        render(body, into: &output)
        return normalize(output)
    }

    private static func render(_ node: Node, into output: inout String) {
        if let text = node as? TextNode {
            output += text.text()
            return
        }

        guard let element = node as? Element else { return }

        switch element.tagName() {
        case "p":
            ensureBlankLine(&output)
            renderChildren(of: element, into: &output)
            ensureBlankLine(&output)
        case "br":
            output += "\n"
        case "pre":
            ensureBlankLine(&output)
            output += (try? element.text()) ?? ""
            ensureBlankLine(&output)
        case "li":
            output += "\n• "
            renderChildren(of: element, into: &output)
            output += "\n"
        case "a":
            let text = (try? element.text()) ?? ""
            let href = (try? element.attr("href")) ?? ""
            if text.isEmpty {
                output += href
            } else {
                output += text
                if shouldShowURL(text: text, href: href) {
                    output += " (\(href))"
                }
            }
        default:
            renderChildren(of: element, into: &output)
        }
    }

    private static func renderChildren(of element: Element, into output: inout String) {
        for child in element.getChildNodes() {
            render(child, into: &output)
        }
    }

    private static func shouldShowURL(text: String, href: String) -> Bool {
        guard href.hasPrefix("http"), text != href else { return false }
        let generic = ["here", "link", "this", "source", "article", "paper", "video", "site"]
        return text.count <= 3 || generic.contains(text.lowercased())
    }

    private static func ensureBlankLine(_ output: inout String) {
        if output.hasSuffix("\n\n") { return }
        if output.hasSuffix("\n") {
            output += "\n"
        } else if !output.isEmpty {
            output += "\n\n"
        }
    }

    private static func normalize(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        result = result.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
