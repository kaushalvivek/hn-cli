import Foundation
import HackerNewsCore

struct FirebaseItemDTO: Decodable {
    let id: Int?
    let deleted: Bool?
    let type: String?
    let by: String?
    let time: Int?
    let text: String?
    let dead: Bool?
    let parent: Int?
    let poll: Int?
    let kids: [Int]?
    let url: String?
    let score: Int?
    let title: String?
    let parts: [Int]?
    let descendants: Int?
}

struct FirebaseUserDTO: Decodable {
    let id: String?
    let created: Int?
    let karma: Int?
    let about: String?
    let submitted: [Int]?
}

struct FirebaseUpdatesDTO: Decodable {
    let items: [Int]?
    let profiles: [String]?
}

extension FirebaseItemDTO {
    func toDomain() throws -> Item {
        guard let id, let itemID = ItemID(validating: id) else {
            throw HackerNewsError.decoding("Firebase item is missing a valid id")
        }

        let createdAt = Date(timeIntervalSince1970: TimeInterval(time ?? 0))
        let author = by.flatMap(UserID.init(validating:))
        let childIDs = (kids ?? []).compactMap(ItemID.init(validating:))
        let parentID = parent.flatMap(ItemID.init(validating:))
        var flags = ItemFlags()
        if deleted == true { flags.insert(.deleted) }
        if dead == true { flags.insert(.dead) }

        // Deleted items lose their type/content but keep their position in a
        // thread. Treat an item without a type the same way.
        guard deleted != true, let type, let kind = ItemKind(rawValue: type) else {
            return Item(
                id: itemID,
                author: author,
                createdAt: createdAt,
                flags: flags,
                content: .deleted(DeletedItem(parentID: parentID, childIDs: childIDs))
            )
        }

        let domainURL = url.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let domainText = text.map(HTMLText.init)
        let domainTitle = HTMLText(title ?? "")

        let content: Item.Content
        switch kind {
        case .story:
            content = .story(
                Story(
                    title: domainTitle,
                    url: domainURL,
                    text: domainText,
                    score: score ?? 0,
                    commentCount: descendants ?? 0,
                    commentIDs: childIDs
                )
            )
        case .comment:
            guard let parentID else {
                throw HackerNewsError.decoding("Comment \(id) is missing a parent")
            }
            content = .comment(
                Comment(
                    parentID: parentID,
                    text: domainText ?? .empty,
                    childIDs: childIDs
                )
            )
        case .job:
            content = .job(
                Job(
                    title: domainTitle,
                    url: domainURL,
                    text: domainText,
                    score: score ?? 0
                )
            )
        case .poll:
            content = .poll(
                Poll(
                    title: domainTitle,
                    text: domainText,
                    score: score ?? 0,
                    commentCount: descendants ?? 0,
                    commentIDs: childIDs,
                    optionIDs: (parts ?? []).compactMap(ItemID.init(validating:))
                )
            )
        case .pollOption:
            guard let pollID = poll.flatMap(ItemID.init(validating:)) else {
                throw HackerNewsError.decoding("Poll option \(id) is missing a poll id")
            }
            content = .pollOption(
                PollOption(
                    pollID: pollID,
                    text: domainText ?? .empty,
                    score: score ?? 0
                )
            )
        }

        return Item(
            id: itemID,
            author: author,
            createdAt: createdAt,
            flags: flags,
            content: content
        )
    }
}

extension FirebaseUserDTO {
    func toDomain() throws -> User {
        guard let id, let userID = UserID(validating: id) else {
            throw HackerNewsError.decoding("Firebase user is missing a valid id")
        }
        return User(
            id: userID,
            createdAt: Date(timeIntervalSince1970: TimeInterval(created ?? 0)),
            karma: karma ?? 0,
            about: about.map(HTMLText.init),
            submittedItemIDs: (submitted ?? []).compactMap(ItemID.init(validating:))
        )
    }
}
