import Foundation
import HackerNewsCore
import HackerNewsAdapters
import ArgumentParser

enum Pagination {
    static func request(page: Int, limit: Int) throws -> PageRequest {
        guard page >= 1 else {
            throw ValidationError("--page must be at least 1")
        }
        guard (1...100).contains(limit) else {
            throw ValidationError("--limit must be between 1 and 100")
        }
        let (offset, overflow) = (page - 1).multipliedReportingOverflow(by: limit)
        guard !overflow else {
            throw ValidationError("--page is too large")
        }
        do {
            return try PageRequest(offset: offset, limit: limit)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}

func requireSession(_ client: HackerNewsClient) async throws -> UserSession {
    guard let session = await client.currentSession() else {
        throw HackerNewsError.unauthenticated
    }
    return session
}

protocol FeedCommand: AsyncParsableCommand {
    var feed: Feed { get }
    var page: Int { get }
    var limit: Int { get }
}

extension FeedCommand {
    func run() async throws {
        let output = Output()
        let client = HackerNewsClient()
        let request = try Pagination.request(page: page, limit: limit)
        try await FeedDisplay(output: output, client: client).show(feed: feed, page: request)
    }
}

struct FeedOptions: ParsableArguments {
    @Option(name: [.short, .long], help: "Number of items (1...100).")
    var limit = 30

    @Option(name: [.short, .long], help: "Page number, starting at 1.")
    var page = 1
}

struct Front: FeedCommand {
    static let configuration = CommandConfiguration(commandName: "front", abstract: "Show the front page.")
    @OptionGroup var options: FeedOptions
    var feed: Feed { .frontPage }
    var page: Int { options.page }
    var limit: Int { options.limit }
}

struct New: FeedCommand {
    static let configuration = CommandConfiguration(commandName: "new", abstract: "Show the newest stories.")
    @OptionGroup var options: FeedOptions
    var feed: Feed { .new }
    var page: Int { options.page }
    var limit: Int { options.limit }
}

struct Best: FeedCommand {
    static let configuration = CommandConfiguration(commandName: "best", abstract: "Show the best stories.")
    @OptionGroup var options: FeedOptions
    var feed: Feed { .best }
    var page: Int { options.page }
    var limit: Int { options.limit }
}

struct Ask: FeedCommand {
    static let configuration = CommandConfiguration(commandName: "ask", abstract: "Show the latest Ask HN posts.")
    @OptionGroup var options: FeedOptions
    var feed: Feed { .ask }
    var page: Int { options.page }
    var limit: Int { options.limit }
}

struct ShowStories: FeedCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show the latest Show HN posts."
    )
    @OptionGroup var options: FeedOptions
    var feed: Feed { .show }
    var page: Int { options.page }
    var limit: Int { options.limit }
}

struct Jobs: FeedCommand {
    static let configuration = CommandConfiguration(commandName: "jobs", abstract: "Show the latest job posts.")
    @OptionGroup var options: FeedOptions
    var feed: Feed { .jobs }
    var page: Int { options.page }
    var limit: Int { options.limit }
}

struct Active: FeedCommand {
    static let configuration = CommandConfiguration(commandName: "active", abstract: "Show threads with recent activity.")
    @OptionGroup var options: FeedOptions
    var feed: Feed { .active }
    var page: Int { options.page }
    var limit: Int { options.limit }
}

struct LatestComments: FeedCommand {
    static let configuration = CommandConfiguration(
        commandName: "comments",
        abstract: "Show the latest comments site-wide.",
        aliases: ["latest-comments"]
    )
    @OptionGroup var options: FeedOptions
    var feed: Feed { .latestComments }
    var page: Int { options.page }
    var limit: Int { options.limit }
}

struct NoobStories: FeedCommand {
    static let configuration = CommandConfiguration(
        commandName: "noob-stories",
        abstract: "Show new submissions from low-karma accounts.",
        aliases: ["noobstories"]
    )
    @OptionGroup var options: FeedOptions
    var feed: Feed { .noobStories }
    var page: Int { options.page }
    var limit: Int { options.limit }
}

struct NoobComments: FeedCommand {
    static let configuration = CommandConfiguration(
        commandName: "noob-comments",
        abstract: "Show new comments from low-karma accounts.",
        aliases: ["noobcomments"]
    )
    @OptionGroup var options: FeedOptions
    var feed: Feed { .noobComments }
    var page: Int { options.page }
    var limit: Int { options.limit }
}

struct Past: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "past",
        abstract: "Show the front page from a past day."
    )

    @Argument(help: "Archive day in YYYY-MM-DD form. Defaults to yesterday.")
    var day: String?

    @OptionGroup var options: FeedOptions

    func run() async throws {
        let calendarDay: CalendarDay
        if let day {
            guard let parsed = CalendarDay(iso8601: day) else {
                throw ValidationError("day must be in YYYY-MM-DD form")
            }
            calendarDay = parsed
        } else {
            calendarDay = try Self.yesterday()
        }

        let output = Output()
        let client = HackerNewsClient()
        let request = try Pagination.request(page: options.page, limit: options.limit)
        try await FeedDisplay(output: output, client: client)
            .show(feed: .pastFrontPage(calendarDay), page: request)
    }

    private static func yesterday() throws -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(byAdding: .day, value: -1, to: Date()) else {
            throw ValidationError("Could not work out yesterday's date")
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            throw ValidationError("Could not work out yesterday's date")
        }
        return try CalendarDay(year: year, month: month, day: day)
    }
}

struct FromSite: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "from",
        abstract: "Show submissions from one site."
    )

    @Argument(help: "Domain, such as github.com.")
    var site: String

    @OptionGroup var options: FeedOptions

    func run() async throws {
        let site = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !site.isEmpty else {
            throw ValidationError("site must not be empty")
        }

        let output = Output()
        let client = HackerNewsClient()
        let request = try Pagination.request(page: options.page, limit: options.limit)
        try await FeedDisplay(output: output, client: client)
            .show(feed: .fromSite(site), page: request)
    }
}

struct Upvoted: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upvoted",
        abstract: "Show items you have upvoted."
    )

    @OptionGroup var options: FeedOptions

    func run() async throws {
        let client = HackerNewsClient()
        let session = try await requireSession(client)
        let request = try Pagination.request(page: options.page, limit: options.limit)
        let fetch = FetchUserActivity(activity: client)
        let result = try await fetch(userID: session.userID, kind: .upvoted, page: request)
        FeedDisplay(output: Output(), client: client)
            .show(page: result, heading: "Upvoted", pageRequest: request)
    }
}

struct Hidden: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hidden",
        abstract: "Show items you have hidden."
    )

    @OptionGroup var options: FeedOptions

    func run() async throws {
        let client = HackerNewsClient()
        let session = try await requireSession(client)
        let request = try Pagination.request(page: options.page, limit: options.limit)
        let fetch = FetchUserActivity(activity: client)
        let result = try await fetch(userID: session.userID, kind: .hidden, page: request)
        FeedDisplay(output: Output(), client: client)
            .show(page: result, heading: "Hidden", pageRequest: request)
    }
}
