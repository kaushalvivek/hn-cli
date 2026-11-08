import ArgumentParser
import HackerNewsAdapters
import HackerNewsTUI

@main
struct HN: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hn",
        abstract: "A command-line client for Hacker News.",
        version: HNVersion.current,
        subcommands: [
            Browse.self,

            Front.self,
            New.self,
            Best.self,
            Ask.self,
            ShowStories.self,
            Jobs.self,
            Active.self,
            LatestComments.self,
            NoobStories.self,
            NoobComments.self,
            Past.self,
            FromSite.self,

            ItemCommand.self,
            ThreadCommand.self,
            ContextCommand.self,
            UserCommand.self,
            SearchCommand.self,
            Leaders.self,
            Updates.self,

            Login.self,
            Signup.self,
            Logout.self,
            Whoami.self,

            Vote.self,
            Submit.self,
            Comment.self,
            Edit.self,
            Delete.self,
            Favorite.self,
            Hide.self,
            FlagItem.self,
            Unflag.self,

            Upvoted.self,
            Hidden.self,
        ]
    )

    @OptionGroup var options: FeedOptions

    func run() async throws {
        if Terminal.isTTY, CommandLine.arguments.count == 1 {
            try await TUI.run(client: HackerNewsClient())
            return
        }

        let client = HackerNewsClient()
        let page = try Pagination.request(page: options.page, limit: options.limit)
        try await FeedDisplay(output: Output(), client: client)
            .show(feed: .frontPage, page: page)
    }
}
