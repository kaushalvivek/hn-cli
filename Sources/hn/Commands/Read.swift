import Foundation
import HackerNewsCore
import HackerNewsAdapters
import ArgumentParser

struct ItemCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "item",
        abstract: "Show one item by ID."
    )

    @Argument(help: "Hacker News item ID.")
    var id: Int

    func run() async throws {
        guard let itemID = ItemID(validating: id) else {
            throw ValidationError("id must be a positive integer")
        }

        let output = Output()
        let client = HackerNewsClient()
        let fetch = FetchItem(items: client)
        guard let item = try await fetch(itemID) else {
            throw HackerNewsError.notFound(.item(itemID))
        }
        try await ItemDisplay.show(item, output: output, client: client)
    }
}

struct ThreadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thread",
        abstract: "Show an item and its comment tree.",
        aliases: ["tree"]
    )

    @Argument(help: "Story, poll, or comment ID.")
    var id: Int

    @Option(name: .long, help: "Maximum reply depth. 0 shows only the root.")
    var depth: Int?

    @Option(name: .long, help: "Maximum number of items to load.")
    var maxNodes = 300

    @Option(name: .long, help: "Maximum concurrent item requests.")
    var concurrency = 8

    func run() async throws {
        guard let itemID = ItemID(validating: id) else {
            throw ValidationError("id must be a positive integer")
        }
        guard maxNodes > 0 else {
            throw ValidationError("--max-nodes must be positive")
        }
        guard concurrency > 0 else {
            throw ValidationError("--concurrency must be positive")
        }
        if let depth, depth < 0 {
            throw ValidationError("--depth must not be negative")
        }

        let output = Output()
        let client = HackerNewsClient()
        let load = LoadThread(items: client)
        let thread = try await load(
            rootID: itemID,
            policy: ThreadLoadPolicy(
                maxDepth: depth,
                maxNodes: maxNodes,
                maxConcurrentRequests: concurrency
            )
        )

        renderRoot(thread.root, output: output)
        output.write()

        if thread.replies.isEmpty {
            output.write(output.dim("No comments."))
        } else {
            for reply in thread.replies {
                renderNode(reply, depth: 0, output: output)
            }
        }

        if !thread.isComplete {
            output.write()
            var note = "Loaded \(thread.loadedItemCount) items; thread is partial"
            if thread.missingItemCount > 0 {
                note += " (\(thread.missingItemCount) unavailable)"
            }
            output.write(output.dim(note))
        }
    }

    private func renderRoot(_ item: Item, output: Output) {
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

        case .job(let job):
            output.write(output.bold(HTMLTextRenderer.plainText(job.title.rawHTML)))
            if let url = job.url { output.write(output.cyan(url.absoluteString)) }
            output.write(
                output.dim(
                    "job · by \(item.author?.rawValue ?? "[deleted]") · \(Format.relativeTime(item.createdAt)) · id \(item.id)"
                )
            )

        case .comment(let comment):
            output.write(
                "\(output.cyan(item.author?.rawValue ?? "[deleted]")) \(output.dim("· \(Format.relativeTime(item.createdAt)) · id \(item.id)"))"
            )
            output.write()
            TextWrap.print(HTMLTextRenderer.plainText(comment.text.rawHTML), indent: "", output: output, width: output.width)

        case .pollOption(let option):
            output.write(HTMLTextRenderer.plainText(option.text.rawHTML))
            output.write(output.dim("poll \(option.pollID) · \(option.score) points · id \(item.id)"))

        case .deleted:
            output.write(output.dim("[deleted item \(item.id)]"))
        }
    }

    private func renderNode(_ node: ThreadNode, depth: Int, output: Output) {
        let indent = String(repeating: "  ", count: depth)

        if node.item.isDeleted {
            output.write(indent + output.dim("[deleted]"))
        } else {
            let dead = node.item.isDead ? " " + output.yellow("[dead]") : ""
            output.write(
                indent
                    + output.cyan(node.item.author?.rawValue ?? "[deleted]")
                    + output.dim(" · \(Format.relativeTime(node.item.createdAt)) · \(node.item.id)")
                    + dead
            )
            if let text = Format.text(of: node.item) {
                TextWrap.print(text, indent: indent, output: output, width: output.width)
            }
        }

        output.write()
        for reply in node.replies {
            renderNode(reply, depth: depth + 1, output: output)
        }
    }
}

struct ContextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "context",
        abstract: "Show a comment in the context of its ancestors."
    )

    @Argument(help: "Comment ID.")
    var id: Int

    @Option(name: .long, help: "Maximum number of ancestors to walk.")
    var maxDepth = 20

    func run() async throws {
        guard let itemID = ItemID(validating: id) else {
            throw ValidationError("id must be a positive integer")
        }
        guard maxDepth > 0 else {
            throw ValidationError("--max-depth must be positive")
        }

        let output = Output()
        let client = HackerNewsClient()
        let fetch = FetchItem(items: client)

        guard var current = try await fetch(itemID) else {
            throw HackerNewsError.notFound(.item(itemID))
        }

        var chain: [Item] = [current]
        var seen: Set<ItemID> = [current.id]
        var depth = 0

        while depth < maxDepth, let parentID = current.parentID {
            guard !seen.contains(parentID) else { break }
            guard let parent = try await fetch(parentID) else { break }
            chain.append(parent)
            seen.insert(parent.id)
            current = parent
            depth += 1
        }

        guard let root = chain.last else {
            throw HackerNewsError.notFound(.item(itemID))
        }
        if root.id == itemID {
            try await ItemDisplay.show(root, output: output, client: client)
            return
        }

        try await ItemDisplay.show(root, output: output, client: client)
        output.write()

        for (index, item) in chain.dropLast().reversed().enumerated() {
            let indent = String(repeating: "  ", count: index)
            let marker = item.id == itemID ? output.yellow("▶ ") : ""
            output.write(
                indent + marker
                    + output.cyan(item.author?.rawValue ?? "[deleted]")
                    + output.dim(" · \(Format.relativeTime(item.createdAt)) · \(item.id)")
            )
            if let text = Format.text(of: item) {
                TextWrap.print(text, indent: indent, output: output, width: output.width)
            }
            output.write()
        }
    }
}

struct UserCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "user",
        abstract: "Show a user profile and activity."
    )

    @Argument(help: "Hacker News username (case-sensitive).")
    var username: String

    @Option(name: .long, help: "Activity: submissions, comments, favorites, favorite-comments, upvoted, hidden.")
    var activity = "submissions"

    @OptionGroup var options: FeedOptions

    func run() async throws {
        guard let userID = UserID(validating: username) else {
            throw ValidationError("username must not be empty")
        }
        guard let kind = Self.activityKind(activity) else {
            throw ValidationError("activity must be submissions, comments, favorites, favorite-comments, upvoted, or hidden")
        }

        let output = Output()
        let client = HackerNewsClient()
        let profile = FetchUserProfile(users: client)
        guard let user = try await profile(userID) else {
            throw HackerNewsError.notFound(.user(userID))
        }

        output.write(output.bold(user.id.rawValue))
        output.write(
            output.dim(
                "\(user.karma) karma · joined \(Format.date(user.createdAt)) · \(user.submittedItemIDs.count) submissions"
            )
        )
        if let about = user.about {
            let text = HTMLTextRenderer.plainText(about.rawHTML)
            if !text.isEmpty {
                output.write()
                TextWrap.print(text, indent: "", output: output, width: output.width)
            }
        }

        output.write()
        let request = try Pagination.request(page: options.page, limit: options.limit)
        let fetch = FetchUserActivity(activity: client)
        let page = try await fetch(userID: userID, kind: kind, page: request)
        FeedDisplay(output: output, client: client)
            .show(page: page, heading: Self.heading(for: kind), pageRequest: request)
    }

    private static func activityKind(_ value: String) -> UserActivityKind? {
        switch value.lowercased() {
        case "submissions", "submitted": .submissions
        case "comments", "threads": .comments
        case "favorites", "favorite-stories": .favoriteStories
        case "favorite-comments": .favoriteComments
        case "upvoted": .upvoted
        case "hidden": .hidden
        default: nil
        }
    }

    private static func heading(for kind: UserActivityKind) -> String {
        switch kind {
        case .submissions: "Submissions"
        case .comments: "Comments"
        case .favoriteStories: "Favorites"
        case .favoriteComments: "Favorite comments"
        case .upvoted: "Upvoted"
        case .hidden: "Hidden"
        }
    }
}

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search stories and comments."
    )

    @Argument(help: "Search terms. May be empty when filtering by author or story.")
    var query: String = ""

    @Option(name: .long, help: "Restrict to an author.")
    var by: String?

    @Option(name: .long, help: "relevance or date.")
    var sort = "relevance"

    @Option(name: .long, help: "story, comment, all, job, poll, or pollopt.")
    var type = "story"

    @OptionGroup var options: FeedOptions

    func run() async throws {
        guard let sort = SearchSort(rawValue: sort.lowercased()) else {
            throw ValidationError("--sort must be relevance or date")
        }
        guard let kinds = Self.kinds(type) else {
            throw ValidationError("--type must be story, comment, all, job, poll, or pollopt")
        }

        let author: UserID?
        if let by {
            guard let userID = UserID(validating: by) else {
                throw ValidationError("--by must not be empty")
            }
            author = userID
        } else {
            author = nil
        }

        let request = try Pagination.request(page: options.page, limit: options.limit)
        let search = SearchHackerNews(provider: HackerNewsClient())
        let results = try await search(
            SearchQuery(
                terms: query,
                kinds: kinds,
                author: author,
                sort: sort,
                page: request
            )
        )

        let output = Output()
        if results.hits.isEmpty {
            output.write(output.dim("No results."))
            return
        }

        for (offset, hit) in results.hits.enumerated() {
            Self.render(hit, rank: results.page * request.limit + offset + 1, output: output)
            output.write()
        }

        output.write(
            output.dim(
                "Page \(results.page + 1)"
                    + (results.hasMore ? " · more results available" : "")
                    + " · \(results.totalHits) total"
            )
        )
    }

    private static func kinds(_ value: String) -> Set<ItemKind>? {
        switch value.lowercased() {
        case "story": [.story]
        case "comment": [.comment]
        case "all": [.story, .comment]
        case "job": [.job]
        case "poll": [.poll]
        case "pollopt", "poll-option": [.pollOption]
        default: nil
        }
    }

    private static func render(_ hit: SearchHit, rank: Int, output: Output) {
        switch hit.kind {
        case .comment:
            output.write(
                "\(output.dim("\(rank).")) \(output.cyan(hit.author?.rawValue ?? "[deleted]")) \(output.dim("· \(Format.relativeTime(hit.createdAt)) · comment \(hit.id)"))"
            )
            if let storyTitle = hit.storyTitle {
                output.write("   " + output.dim("on \(HTMLTextRenderer.plainText(storyTitle.rawHTML))"))
            }
            if let text = hit.text {
                let rendered = HTMLTextRenderer.plainText(text.rawHTML).replacingOccurrences(of: "\n", with: " ")
                output.write("   " + String(rendered.prefix(280)))
            }

        default:
            let title = hit.title.map { HTMLTextRenderer.plainText($0.rawHTML) } ?? "(untitled)"
            output.write("\(output.dim("\(rank).")) \(output.bold(title))")
            var parts: [String] = []
            if let domain = Format.domain(of: hit.url) { parts.append(domain) }
            if let score = hit.score { parts.append("\(score) points") }
            if let comments = hit.commentCount { parts.append("\(comments) comments") }
            if let author = hit.author { parts.append("by \(author.rawValue)") }
            parts.append(Format.relativeTime(hit.createdAt))
            output.write("   " + output.dim(parts.joined(separator: " · ")))
            if let text = hit.text {
                let rendered = HTMLTextRenderer.plainText(text.rawHTML).replacingOccurrences(of: "\n", with: " ")
                if !rendered.isEmpty {
                    output.write("   " + output.dim(String(rendered.prefix(220))))
                }
            }
        }
    }
}

struct Leaders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaders",
        abstract: "Show the top users by karma."
    )

    func run() async throws {
        let output = Output()
        let fetch = FetchLeaders(provider: HackerNewsClient())
        let leaders = try await fetch()

        for (index, entry) in leaders.enumerated() {
            let rank = "\(index + 1)."
            output.write(
                "\(output.dim(rank.padding(toLength: 5, withPad: " ", startingAt: 0))) "
                    + output.cyan(entry.userID.rawValue)
                    + (entry.karma > 0 ? output.dim(" · \(entry.karma) karma") : "")
            )
        }
    }
}

struct Updates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "updates",
        abstract: "Show recently changed items and profiles."
    )

    @Flag(name: .long, help: "Show item IDs.")
    var items = false

    @Flag(name: .long, help: "Show profile IDs.")
    var profiles = false

    func run() async throws {
        let output = Output()
        let fetch = FetchUpdates(provider: HackerNewsClient())
        let updates = try await fetch()

        let showItems = items || !profiles
        let showProfiles = profiles || !items

        if showItems {
            output.write(output.bold("Changed items · \(updates.itemIDs.count)"))
            if !updates.itemIDs.isEmpty {
                output.write(updates.itemIDs.map(\.description).joined(separator: " "))
            }
            output.write()
        }
        if showProfiles {
            output.write(output.bold("Changed profiles · \(updates.profileIDs.count)"))
            if !updates.profileIDs.isEmpty {
                output.write(updates.profileIDs.map(\.rawValue).joined(separator: " "))
            }
        }
    }
}
