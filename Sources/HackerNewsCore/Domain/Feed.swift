/// An ordered list of items on Hacker News.
public enum Feed: Sendable, Hashable, Codable {
    /// The front page (site path `news`), backed by Firebase `topstories`.
    case frontPage

    /// Newest stories (`newest`).
    case new

    /// Top links (`best`).
    case best

    /// Latest Ask HN posts (`ask`).
    case ask

    /// Latest Show HN posts (`show`).
    case show

    /// Latest job posts (`jobs`).
    case jobs

    /// Threads with recent activity (`active`).
    case active

    /// Newest comments site-wide (`newcomments`).
    case latestComments

    /// Newest submissions from low-karma accounts (`noobstories`).
    case noobStories

    /// Newest comments from low-karma accounts (`noobcomments`).
    case noobComments

    /// The front page as it appeared on a given day (`front?day=YYYY-MM-DD`).
    case pastFrontPage(CalendarDay)

    /// Submissions from one site (`from?site=example.com`).
    case fromSite(String)
}
