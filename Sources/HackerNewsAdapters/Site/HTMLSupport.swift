import Foundation
import HackerNewsCore
import SwiftSoup

struct ParsedForm {
    let action: String
    let method: String
    let hiddenFields: [String: String]
    let textAreaName: String?
}

enum HTMLSupport {
    static func document(from html: String) throws -> Document {
        do {
            return try SwiftSoup.parse(html)
        } catch {
            throw HackerNewsError.decoding("Could not parse HN HTML: \(error)")
        }
    }

    static func title(of document: Document) -> String? {
        try? document.title()
    }

    static func itemIDs(in document: Document) throws -> [ItemID] {
        var seen: Set<ItemID> = []
        var ids: [ItemID] = []

        for row in try document.select("tr.athing").array() {
            let raw = try row.attr("id")
            guard let value = Int(raw), let id = ItemID(validating: value), !seen.contains(id) else {
                continue
            }
            seen.insert(id)
            ids.append(id)
        }
        return ids
    }

    static func moreLink(in document: Document) throws -> String? {
        guard let link = try document.select("a.morelink").first() else { return nil }
        let href = try link.attr("href")
        guard !href.isEmpty else { return nil }
        return href.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func authToken(in html: String) -> String? {
        let normalized = html.replacingOccurrences(of: "&amp;", with: "&")
        return firstMatch(pattern: #"[?&]auth=([A-Za-z0-9]+)"#, in: normalized)
    }

    static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[valueRange])
    }

    static func form(
        in document: Document,
        containingInput name: String
    ) throws -> ParsedForm? {
        for form in try document.select("form").array() {
            if try form.select("input[name=\(name)]").first() != nil {
                return try parse(form: form)
            }
        }
        return nil
    }

    static func form(
        in document: Document,
        containingTextArea named: String? = nil
    ) throws -> ParsedForm? {
        for form in try document.select("form").array() {
            let selector = named.map { "textarea[name=\($0)]" } ?? "textarea"
            if try form.select(selector).first() != nil {
                return try parse(form: form)
            }
        }
        return nil
    }

    static func form(
        in document: Document,
        actionContaining fragment: String
    ) throws -> ParsedForm? {
        for form in try document.select("form").array() {
            if (try form.attr("action")).lowercased().contains(fragment.lowercased()) {
                return try parse(form: form)
            }
        }
        return nil
    }

    static func isLoginPage(_ document: Document) throws -> Bool {
        try document.select("input[name=acct]").first() != nil
            && document.select("input[name=pw]").first() != nil
    }

    static func feedEntries(
        in document: Document,
        defaultKind: ItemKind
    ) throws -> [SiteFeedEntry] {
        var entries: [SiteFeedEntry] = []

        for row in try document.select("tr.athing").array() {
            let rawID = try row.attr("id")
            guard let idValue = Int(rawID), let id = ItemID(validating: idValue) else {
                continue
            }

            if let titleline = try row.select("span.titleline > a").first() {
                let title = try titleline.text()
                let href = try titleline.attr("href")
                let url: URL? = href.hasPrefix("item?id=") ? nil : URL(string: href)
                let subtext = try row.nextElementSibling()?.select(".subtext").first()

                var score: Int?
                var author: UserID?
                var createdAt = Date(timeIntervalSince1970: 0)
                var commentCount: Int?

                if let subtext {
                    if let scoreText = try subtext.select("span.score").first()?.text() {
                        score = firstInt(in: scoreText)
                    }
                    if let userHref = try subtext.select("a[href^=user?id=]").first()?.attr("href") {
                        author = queryValue(named: "id", in: userHref).flatMap(UserID.init(validating:))
                    }
                    if let age = try subtext.select("span.age").first()?.attr("title") {
                        createdAt = parseAge(age)
                    }
                    for link in try subtext.select("a[href^=item?id=]").array() {
                        if let value = firstInt(in: try link.text()) {
                            commentCount = value
                        }
                    }
                }

                let kind: ItemKind = defaultKind == .job ? .job : .story
                entries.append(
                    SiteFeedEntry(
                        id: id,
                        kind: kind,
                        title: title.isEmpty ? nil : title,
                        url: url,
                        text: nil,
                        author: author,
                        createdAt: createdAt,
                        score: score,
                        commentCount: commentCount,
                        storyID: id,
                        storyTitle: nil,
                        parentID: nil,
                        isDead: false,
                        isDeleted: false
                    )
                )
                continue
            }

            guard let commentText = try row.select("div.commtext").first() else {
                continue
            }

            let comhead = try row.select(".comhead").first()
            let authorHref = try comhead?.select("a[href^=user?id=]").first()?.attr("href")
            let author = authorHref
                .flatMap { queryValue(named: "id", in: $0) }
                .flatMap(UserID.init(validating:))
            let age = try comhead?.select("span.age").first()?.attr("title") ?? ""
            let createdAt = parseAge(age)

            var parentID: ItemID?
            var storyID: ItemID?
            var storyTitle: String?
            if let comhead {
                for link in try comhead.select("a[href^=item?id=]").array() {
                    let text = try link.text()
                    if text == "parent", parentID == nil {
                        parentID = queryValue(named: "id", in: try link.attr("href"))
                            .flatMap(Int.init)
                            .flatMap(ItemID.init(validating:))
                    }
                }
                if let storyLink = try comhead.select("span.onstory a").first() {
                    storyTitle = try storyLink.text()
                    storyID = queryValue(named: "id", in: try storyLink.attr("href"))
                        .flatMap(Int.init)
                        .flatMap(ItemID.init(validating:))
                }
            }

            let rawText = try commentText.html()
            let plain = try commentText.text()
            let isDeleted = plain.trimmingCharacters(in: .whitespacesAndNewlines) == "[deleted]"
            let isDead = plain.trimmingCharacters(in: .whitespacesAndNewlines) == "[dead]"

            entries.append(
                SiteFeedEntry(
                    id: id,
                    kind: .comment,
                    title: nil,
                    url: nil,
                    text: isDeleted ? nil : HTMLText(rawText),
                    author: author,
                    createdAt: createdAt,
                    score: nil,
                    commentCount: nil,
                    storyID: storyID,
                    storyTitle: storyTitle,
                    parentID: parentID,
                    isDead: isDead,
                    isDeleted: isDeleted
                )
            )
        }

        return entries
    }

    static func leaders(in document: Document) throws -> [LeaderboardEntry] {
        var entries: [LeaderboardEntry] = []
        for row in try document.select("tr.athing").array() {
            guard let link = try row.select("a[href^=user?id=]").first() else { continue }
            let href = try link.attr("href")
            guard let username = queryValue(named: "id", in: href),
                  let userID = UserID(validating: username)
            else {
                continue
            }

            let cells = try row.select("td").array()
            let karma = cells.last.flatMap { Int((try? $0.text()) ?? "") } ?? 0
            entries.append(LeaderboardEntry(userID: userID, karma: karma))
        }
        return entries
    }

    static func queryValue(named name: String, in url: String) -> String? {
        guard let components = URLComponents(string: url.hasPrefix("/") ? "https://news.ycombinator.com\(url)" : url) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    static func firstInt(in text: String) -> Int? {
        for part in text.split(whereSeparator: { !$0.isNumber }) {
            if let value = Int(part) { return value }
        }
        return nil
    }

    static func parseAge(_ value: String) -> Date {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Date(timeIntervalSince1970: 0) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: trimmed) ?? Date(timeIntervalSince1970: 0)
    }

    private static func parse(form: Element) throws -> ParsedForm {
        var fields: [String: String] = [:]
        for input in try form.select("input").array() {
            let type = (try input.attr("type")).lowercased()
            let name = try input.attr("name")
            guard !name.isEmpty, name != "creating" else { continue }
            guard type == "hidden" else { continue }
            fields[name] = try input.attr("value")
        }

        return ParsedForm(
            action: try form.attr("action"),
            method: (try form.attr("method")).isEmpty ? "post" : (try form.attr("method")),
            hiddenFields: fields,
            textAreaName: try form.select("textarea").first()?.attr("name")
        )
    }
}
