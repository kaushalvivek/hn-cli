import Foundation
import ArgumentParser
import HackerNewsCore
import HackerNewsAdapters

struct Vote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vote",
        abstract: "Upvote an item, downvote it, or remove your vote."
    )

    @Argument(help: "Item ID.")
    var id: Int

    @Flag(name: .long, help: "Downvote instead of upvoting.")
    var down = false

    @Flag(name: .long, help: "Remove your vote.")
    var undo = false

    func run() async throws {
        guard let itemID = ItemID(validating: id) else {
            throw ValidationError("id must be a positive integer")
        }
        guard !(down && undo) else {
            throw ValidationError("--down and --undo cannot be used together")
        }

        let direction: VoteDirection = undo ? .unvote : (down ? .down : .up)
        let client = HackerNewsClient()
        try await client.vote(on: itemID, direction: direction)

        let output = Output()
        switch direction {
        case .up: output.write("Upvoted \(itemID).")
        case .down: output.write("Downvoted \(itemID).")
        case .unvote: output.write("Removed your vote on \(itemID).")
        }
    }
}

struct Submit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submit",
        abstract: "Submit a story to Hacker News."
    )

    @Option(name: [.short, .long], help: "Story title.")
    var title: String

    @Option(name: .long, help: "Story URL.")
    var url: String?

    @Option(name: .long, help: "Story text. Use - to read stdin, or omit to open $EDITOR.")
    var text: String?

    func run() async throws {
        let resolvedURL: URL?
        if let url, !url.isEmpty {
            guard let parsed = URL(string: url), parsed.scheme != nil else {
                throw ValidationError("--url must be a valid absolute URL")
            }
            resolvedURL = parsed
        } else {
            resolvedURL = nil
        }

        let resolvedText: String?
        if resolvedURL == nil {
            resolvedText = try TextInput.resolve(text)
        } else if let text, !text.isEmpty {
            resolvedText = try TextInput.resolve(text)
        } else {
            resolvedText = nil
        }

        let submission = try StorySubmission(
            title: title,
            url: resolvedURL,
            text: resolvedText
        )

        let client = HackerNewsClient()
        let itemID = try await client.submitStory(submission)
        let output = Output()
        if let itemID {
            output.write("Submitted: \(Format.itemURL(itemID))")
        } else {
            output.write("Submitted to Hacker News.")
        }
    }
}

struct Comment: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "comment",
        abstract: "Post a comment or reply.",
        aliases: ["reply"]
    )

    @Argument(help: "Parent story or comment ID.")
    var parentID: Int

    @Option(name: .long, help: "Comment text. Use - to read stdin, or omit to open $EDITOR.")
    var text: String?

    func run() async throws {
        guard let parent = ItemID(validating: parentID) else {
            throw ValidationError("parent id must be a positive integer")
        }

        let body = try TextInput.resolve(text)
        let submission = try CommentSubmission(parentID: parent, text: body)

        let client = HackerNewsClient()
        let itemID = try await client.submitComment(submission)
        let output = Output()
        if let itemID {
            output.write("Comment posted: \(Format.itemURL(itemID))")
        } else {
            output.write("Comment posted.")
        }
    }
}

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit one of your comments or stories."
    )

    @Argument(help: "Item ID.")
    var id: Int

    @Option(name: .long, help: "New text. Use - to read stdin, or omit to open $EDITOR.")
    var text: String?

    func run() async throws {
        guard let itemID = ItemID(validating: id) else {
            throw ValidationError("id must be a positive integer")
        }

        let body = try TextInput.resolve(text)
        let client = HackerNewsClient()
        try await client.editItem(id: itemID, text: body)
        Output().write("Edited \(itemID).")
    }
}

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete one of your comments or stories."
    )

    @Argument(help: "Item ID.")
    var id: Int

    @Flag(name: .long, help: "Do not ask for confirmation.")
    var yes = false

    func run() async throws {
        guard let itemID = ItemID(validating: id) else {
            throw ValidationError("id must be a positive integer")
        }
        guard yes || confirm("Delete item \(itemID.rawValue)?") else {
            Output().write("Cancelled.")
            return
        }

        let client = HackerNewsClient()
        try await client.deleteItem(id: itemID)
        Output().write("Deleted \(itemID).")
    }
}

struct Favorite: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "favorite",
        abstract: "Add an item to your favorites, or remove it."
    )

    @Argument(help: "Item ID.")
    var id: Int

    @Flag(name: .long, help: "Remove the item from favorites.")
    var undo = false

    func run() async throws {
        guard let itemID = ItemID(validating: id) else {
            throw ValidationError("id must be a positive integer")
        }

        let client = HackerNewsClient()
        try await client.setFavorite(!undo, on: itemID)
        Output().write(undo ? "Removed \(itemID) from favorites." : "Favorited \(itemID).")
    }
}

struct Hide: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hide",
        abstract: "Hide an item, or unhide it."
    )

    @Argument(help: "Item ID.")
    var id: Int

    @Flag(name: .long, help: "Unhide the item.")
    var undo = false

    func run() async throws {
        guard let itemID = ItemID(validating: id) else {
            throw ValidationError("id must be a positive integer")
        }

        let client = HackerNewsClient()
        try await client.setHidden(!undo, on: itemID)
        Output().write(undo ? "Unhid \(itemID)." : "Hid \(itemID).")
    }
}

struct FlagItem: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flag",
        abstract: "Flag an item for moderation."
    )

    @Argument(help: "Item ID.")
    var id: Int

    @Option(name: .long, help: "Optional reason.")
    var reason = ""

    func run() async throws {
        guard let itemID = ItemID(validating: id) else {
            throw ValidationError("id must be a positive integer")
        }

        let client = HackerNewsClient()
        try await client.flag(itemID: itemID, reason: reason)
        Output().write("Flagged \(itemID).")
    }
}

struct Unflag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unflag",
        abstract: "Remove a flag from an item."
    )

    @Argument(help: "Item ID.")
    var id: Int

    func run() async throws {
        guard let itemID = ItemID(validating: id) else {
            throw ValidationError("id must be a positive integer")
        }

        let client = HackerNewsClient()
        try await client.unflag(itemID: itemID)
        Output().write("Unflagged \(itemID).")
    }
}
