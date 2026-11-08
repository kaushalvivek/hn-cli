import Foundation
import HackerNewsCore
import HackerNewsAdapters

public enum Source: Hashable, Sendable {
    case feed(Feed)
    case upvoted
    case hidden
    case search(String)

    public var label: String {
        switch self {
        case .feed(.frontPage): "front"
        case .feed(.new): "new"
        case .feed(.best): "best"
        case .feed(.ask): "ask"
        case .feed(.show): "show"
        case .feed(.jobs): "jobs"
        case .feed(.active): "active"
        case .feed(.latestComments): "comments"
        case .feed(.noobStories): "noob stories"
        case .feed(.noobComments): "noob comments"
        case .feed(.pastFrontPage(let day)): "past \(day)"
        case .feed(.fromSite(let site)): "from \(site)"
        case .upvoted: "upvoted"
        case .hidden: "hidden"
        case .search(let query): "search \(query)"
        }
    }

    public var requiresAuthentication: Bool {
        switch self {
        case .upvoted, .hidden: true
        default: false
        }
    }

    public var feed: Feed? {
        if case .feed(let feed) = self { return feed }
        return nil
    }
}

public struct SidebarSection: Sendable {
    public let title: String
    public let items: [Source]

    public init(title: String, items: [Source]) {
        self.title = title
        self.items = items
    }

    public static func standard(pastDay: CalendarDay) -> [SidebarSection] {
        [
            SidebarSection(
                title: "FEEDS",
                items: [
                    .feed(.frontPage),
                    .feed(.new),
                    .feed(.best),
                    .feed(.ask),
                    .feed(.show),
                    .feed(.jobs),
                ]
            ),
            SidebarSection(
                title: "MORE",
                items: [
                    .feed(.active),
                    .feed(.latestComments),
                    .feed(.noobStories),
                    .feed(.noobComments),
                    .feed(.pastFrontPage(pastDay)),
                ]
            ),
            SidebarSection(
                title: "YOURS",
                items: [
                    .upvoted,
                    .hidden,
                ]
            ),
        ]
    }
}

public struct TUIEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case story
        case comment
        case job
        case poll
        case pollOption
        case deleted
    }

    public let id: ItemID
    public let kind: Kind
    public let title: String?
    public let url: URL?
    public let text: String?
    public let author: UserID?
    public let createdAt: Date
    public let score: Int?
    public let commentCount: Int?
    public let storyID: ItemID?
    public let storyTitle: String?
    public let parentID: ItemID?
    public let isDead: Bool
    public let isDeleted: Bool

    public init(item: Item) {
        self.id = item.id
        self.kind = switch item.content {
        case .story: .story
        case .comment: .comment
        case .job: .job
        case .poll: .poll
        case .pollOption: .pollOption
        case .deleted: .deleted
        }
        self.title = item.title.map { HTMLTextRenderer.plainText($0.rawHTML) }
        self.text = item.text.map { HTMLTextRenderer.plainText($0.rawHTML) }
        self.url = switch item.content {
        case .story(let story): story.url
        case .job(let job): job.url
        default: nil
        }
        self.author = item.author
        self.createdAt = item.createdAt
        self.score = item.score
        self.commentCount = item.commentCount
        self.storyID = nil
        self.storyTitle = nil
        self.parentID = item.parentID
        self.isDead = item.isDead
        self.isDeleted = item.isDeleted || item.kind == nil
    }

    public init(siteEntry: SiteFeedEntry) {
        self.id = siteEntry.id
        self.kind = switch siteEntry.kind {
        case .story: .story
        case .comment: .comment
        case .job: .job
        case .poll: .poll
        case .pollOption: .pollOption
        }
        self.title = siteEntry.title
        self.text = siteEntry.text.map { HTMLTextRenderer.plainText($0.rawHTML) }
        self.url = siteEntry.url
        self.author = siteEntry.author
        self.createdAt = siteEntry.createdAt
        self.score = siteEntry.score
        self.commentCount = siteEntry.commentCount
        self.storyID = siteEntry.storyID
        self.storyTitle = siteEntry.storyTitle
        self.parentID = siteEntry.parentID
        self.isDead = siteEntry.isDead
        self.isDeleted = siteEntry.isDeleted
    }

    public init(hit: SearchHit) {
        self.id = hit.id
        self.kind = switch hit.kind {
        case .story: .story
        case .comment: .comment
        case .job: .job
        case .poll: .poll
        case .pollOption: .pollOption
        }
        self.title = hit.title.map { HTMLTextRenderer.plainText($0.rawHTML) }
        self.text = hit.text.map { HTMLTextRenderer.plainText($0.rawHTML) }
        self.url = hit.url
        self.author = hit.author
        self.createdAt = hit.createdAt
        self.score = hit.score
        self.commentCount = hit.commentCount
        self.storyID = hit.storyID
        self.storyTitle = hit.storyTitle.map { HTMLTextRenderer.plainText($0.rawHTML) }
        self.parentID = hit.parentID
        self.isDead = false
        self.isDeleted = false
    }

    public var domain: String? {
        guard let host = url?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public var isComment: Bool {
        kind == .comment
    }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let storyTitle, !storyTitle.isEmpty { return storyTitle }
        if let text, !text.isEmpty { return text }
        return "[deleted]"
    }
}

public enum TUIDate {
    public static func yesterday(calendar: Calendar = .current, now: Date = Date()) -> CalendarDay {
        let date = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        if let year = components.year,
           let month = components.month,
           let day = components.day,
           let value = try? CalendarDay(year: year, month: month, day: day)
        {
            return value
        }
        return try! CalendarDay(year: 1970, month: 1, day: 1)
    }
}
