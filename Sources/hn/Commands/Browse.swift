import ArgumentParser
import HackerNewsAdapters
import HackerNewsTUI
import HackerNewsCore

struct Browse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browse",
        abstract: "Open the interactive Hacker News browser.",
        aliases: ["tui", "ui"]
    )

    @Option(name: .long, help: "Initial feed: front, new, best, ask, show, jobs, active, comments.")
    var feed: String?

    func run() async throws {
        let source: Source
        if let feed {
            switch feed.lowercased() {
            case "front", "news", "top": source = .feed(.frontPage)
            case "new", "newest": source = .feed(.new)
            case "best": source = .feed(.best)
            case "ask": source = .feed(.ask)
            case "show": source = .feed(.show)
            case "jobs": source = .feed(.jobs)
            case "active": source = .feed(.active)
            case "comments": source = .feed(.latestComments)
            case "noob-stories": source = .feed(.noobStories)
            case "noob-comments": source = .feed(.noobComments)
            case "upvoted": source = .upvoted
            case "hidden": source = .hidden
            default:
                throw ValidationError("unknown feed: \(feed)")
            }
        } else {
            source = .feed(.frontPage)
        }

        try await TUI.run(client: HackerNewsClient(), initialSource: source)
    }
}
