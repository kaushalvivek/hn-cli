import Darwin
import Foundation
import HackerNewsCore
import HackerNewsAdapters

struct Output {
    let useColor: Bool
    let width: Int

    init() {
        let noColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        let dumb = ProcessInfo.processInfo.environment["TERM"] == "dumb"
        self.useColor = isatty(STDOUT_FILENO) != 0 && !noColor && !dumb
        self.width = Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 100
    }

    func paint(_ text: String, _ code: String) -> String {
        guard useColor else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    func bold(_ text: String) -> String { paint(text, "1") }
    func dim(_ text: String) -> String { paint(text, "2") }
    func red(_ text: String) -> String { paint(text, "31") }
    func green(_ text: String) -> String { paint(text, "32") }
    func yellow(_ text: String) -> String { paint(text, "33") }
    func cyan(_ text: String) -> String { paint(text, "36") }

    func write(_ text: String = "") {
        print(text)
    }

    func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

enum Format {
    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:
            return "\(Int(seconds))s ago"
        case ..<3600:
            return "\(Int(seconds / 60))m ago"
        case ..<86_400:
            return "\(Int(seconds / 3600))h ago"
        case ..<2_592_000:
            return "\(Int(seconds / 86_400))d ago"
        case ..<31_536_000:
            return "\(Int(seconds / 2_592_000))mo ago"
        default:
            return "\(Int(seconds / 31_536_000))y ago"
        }
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func domain(of url: URL?) -> String? {
        guard let host = url?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func title(of item: Item) -> String? {
        item.title.map { HTMLTextRenderer.plainText($0.rawHTML) }
    }

    static func text(of item: Item) -> String? {
        guard let text = item.text else { return nil }
        let rendered = HTMLTextRenderer.plainText(text.rawHTML)
        return rendered.isEmpty ? nil : rendered
    }

    static func author(of item: Item) -> String {
        item.author?.rawValue ?? "[deleted]"
    }

    static func itemURL(_ id: ItemID) -> String {
        "https://news.ycombinator.com/item?id=\(id.rawValue)"
    }
}

enum TextWrap {
    static func lines(_ text: String, width: Int) -> [String] {
        let usable = max(20, width)
        var result: [String] = []

        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if paragraph.isEmpty {
                result.append("")
                continue
            }

            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if candidate.count <= usable {
                    line = candidate
                } else {
                    if !line.isEmpty { result.append(line) }
                    line = String(word)
                }
            }
            if !line.isEmpty { result.append(line) }
        }

        return result
    }

    static func print(
        _ text: String,
        indent: String,
        output: Output,
        width: Int
    ) {
        for line in lines(text, width: width - indent.count) {
            output.write(indent + line)
        }
    }
}

struct FeedDisplay {
    let output: Output
    let client: HackerNewsClient

    func show(feed: Feed, page: PageRequest) async throws {
        let fetch = FetchFeedPage(feeds: client, items: client)
        let result = try await fetch(feed: feed, page: page)
        show(page: result, heading: heading(for: feed), pageRequest: page)
    }

    func show(page result: ItemPage, heading: String?, pageRequest: PageRequest) {
        if let heading {
            output.write(output.bold(heading))
            output.write()
        }

        if result.items.isEmpty {
            output.write(output.dim("No items."))
            return
        }

        for (offset, item) in result.items.enumerated() {
            render(item, rank: result.offset + offset + 1)
        }

        output.write()
        output.write(
            output.dim(
                "Page \(pageRequest.offset / pageRequest.limit + 1) · showing \(result.offset + 1)–\(result.offset + result.items.count)"
                    + (result.hasMore ? " · more available" : "")
            )
        )
    }

    func render(_ item: Item, rank: Int) {
        switch item.content {
        case .story(let story):
            output.write(
                "\(output.dim("\(rank).")) \(output.bold(HTMLTextRenderer.plainText(story.title.rawHTML)))"
            )
            var parts: [String] = []
            if let domain = Format.domain(of: story.url) {
                parts.append(domain)
            } else {
                parts.append("news.ycombinator.com")
            }
            parts.append("\(story.score) points")
            parts.append("\(story.commentCount) comments")
            parts.append("by \(item.author?.rawValue ?? "[deleted]")")
            parts.append(Format.relativeTime(item.createdAt))
            output.write("   " + output.dim(parts.joined(separator: " · ")))
            if let text = Format.text(of: item) {
                let snippet = String(text.prefix(220)).replacingOccurrences(of: "\n", with: " ")
                output.write("   " + output.dim(snippet))
            }

        case .job(let job):
            output.write("\(output.dim("\(rank).")) \(output.bold(HTMLTextRenderer.plainText(job.title.rawHTML)))")
            var parts = ["job"]
            if let domain = Format.domain(of: job.url) { parts.append(domain) }
            parts.append("by \(item.author?.rawValue ?? "[deleted]")")
            parts.append(Format.relativeTime(item.createdAt))
            output.write("   " + output.dim(parts.joined(separator: " · ")))

        case .poll(let poll):
            output.write("\(output.dim("\(rank).")) \(output.bold(HTMLTextRenderer.plainText(poll.title.rawHTML)))")
            output.write(
                "   " + output.dim(
                    "poll · \(poll.score) points · \(poll.commentCount) comments · by \(item.author?.rawValue ?? "[deleted]") · \(Format.relativeTime(item.createdAt))"
                )
            )

        case .comment(let comment):
            output.write(
                "\(output.dim("\(rank).")) \(output.cyan(item.author?.rawValue ?? "[deleted]")) \(output.dim("· \(Format.relativeTime(item.createdAt)) · comment \(item.id)"))"
            )
            let text = HTMLTextRenderer.plainText(comment.text.rawHTML)
            let snippet = String(text.prefix(260)).replacingOccurrences(of: "\n", with: " ")
            output.write("   " + snippet)
            output.write("   " + output.dim("parent \(comment.parentID)"))

        case .pollOption(let option):
            output.write("\(output.dim("\(rank).")) \(HTMLTextRenderer.plainText(option.text.rawHTML))")
            output.write("   " + output.dim("poll \(option.pollID) · \(option.score) points"))

        case .deleted:
            output.write("\(output.dim("\(rank).")) \(output.dim("[deleted]"))")
        }
    }

    private func heading(for feed: Feed) -> String? {
        switch feed {
        case .frontPage: "Front page"
        case .new: "New stories"
        case .best: "Best stories"
        case .ask: "Ask HN"
        case .show: "Show HN"
        case .jobs: "Jobs"
        case .active: "Active threads"
        case .latestComments: "Latest comments"
        case .noobStories: "New submissions"
        case .noobComments: "New comments"
        case .pastFrontPage(let day): "Front page · \(day)"
        case .fromSite(let site): "From \(site)"
        }
    }
}

enum ItemDisplay {
    static func show(_ item: Item, output: Output, client: HackerNewsClient) async throws {
        switch item.content {
        case .story(let story):
            output.write(output.bold(HTMLTextRenderer.plainText(story.title.rawHTML)))
            if let url = story.url {
                output.write(output.cyan(url.absoluteString))
            }
            output.write(
                output.dim(
                    "\(story.score) points · \(story.commentCount) comments · by \(item.author?.rawValue ?? "[deleted]") · \(Format.relativeTime(item.createdAt)) · id \(item.id)"
                )
            )
            if let text = Format.text(of: item) {
                output.write()
                TextWrap.print(text, indent: "", output: output, width: output.width)
            }
            output.write()
            output.write(output.dim("Comments: hn thread \(item.id)"))

        case .job(let job):
            output.write(output.bold(HTMLTextRenderer.plainText(job.title.rawHTML)))
            if let url = job.url {
                output.write(output.cyan(url.absoluteString))
            }
            output.write(
                output.dim(
                    "job · \(job.score) points · by \(item.author?.rawValue ?? "[deleted]") · \(Format.relativeTime(item.createdAt)) · id \(item.id)"
                )
            )
            if let text = Format.text(of: item) {
                output.write()
                TextWrap.print(text, indent: "", output: output, width: output.width)
            }

        case .poll(let poll):
            output.write(output.bold(HTMLTextRenderer.plainText(poll.title.rawHTML)))
            output.write(
                output.dim(
                    "poll · \(poll.score) points · \(poll.commentCount) comments · by \(item.author?.rawValue ?? "[deleted]") · \(Format.relativeTime(item.createdAt)) · id \(item.id)"
                )
            )
            if let text = Format.text(of: item) {
                output.write()
                TextWrap.print(text, indent: "", output: output, width: output.width)
            }
            if !poll.optionIDs.isEmpty {
                output.write()
                output.write(output.bold("Options"))
                for optionID in poll.optionIDs {
                    if let option = try await client.item(id: optionID) {
                        switch option.content {
                        case .pollOption(let value):
                            output.write("  • \(HTMLTextRenderer.plainText(value.text.rawHTML)) \(output.dim("(\(value.score))"))")
                        default:
                            break
                        }
                    }
                }
            }
            output.write()
            output.write(output.dim("Comments: hn thread \(item.id)"))

        case .comment(let comment):
            output.write("\(output.cyan(item.author?.rawValue ?? "[deleted]")) \(output.dim("· \(Format.relativeTime(item.createdAt)) · id \(item.id)"))")
            output.write()
            TextWrap.print(HTMLTextRenderer.plainText(comment.text.rawHTML), indent: "", output: output, width: output.width)
            output.write()
            output.write(output.dim("Parent: hn item \(comment.parentID)"))
            output.write(output.dim("Replies: hn thread \(item.id)"))

        case .pollOption(let option):
            output.write(HTMLTextRenderer.plainText(option.text.rawHTML))
            output.write(output.dim("poll \(option.pollID) · \(option.score) points · id \(item.id)"))

        case .deleted:
            output.write(output.dim("[deleted item \(item.id)]"))
        }
    }
}
