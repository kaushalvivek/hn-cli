import Foundation
import HackerNewsCore

struct AlgoliaItemDTO: Decodable {
    let id: Int?
    let author: String?
    let createdAt: Int?
    let type: String?
    let title: String?
    let url: String?
    let text: String?
    let points: Int?
    let parentID: Int?
    let storyID: Int?
    let children: [AlgoliaItemDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case createdAt = "created_at_i"
        case type
        case title
        case url
        case text
        case points
        case parentID = "parent_id"
        case storyID = "story_id"
        case children
    }
}

extension AlgoliaItemDTO {
    func toThread() throws -> HackerNewsCore.Thread {
        guard let idValue = id, let rootID = ItemID(validating: idValue) else {
            throw HackerNewsError.decoding("Algolia item tree has no valid root id")
        }

        let children = children ?? []
        let rootItem = try makeItem(id: rootID, isRoot: true)
        let nodes = try children.map { try makeNode($0) }
        let loaded = 1 + nodes.reduce(0) { $0 + count($1) }

        return HackerNewsCore.Thread(
            root: rootItem,
            replies: nodes,
            loadedItemCount: loaded,
            missingItemCount: 0,
            isComplete: true
        )
    }

    private func makeNode(_ dto: AlgoliaItemDTO) throws -> ThreadNode {
        guard let idValue = dto.id, let id = ItemID(validating: idValue) else {
            throw HackerNewsError.decoding("Algolia item tree has a child without an id")
        }
        let item = try dto.makeItem(id: id, isRoot: false)
        let replies = try (dto.children ?? []).map { try makeNode($0) }
        return ThreadNode(item: item, replies: replies)
    }

    private func makeItem(id: ItemID, isRoot: Bool) throws -> Item {
        let author = author.flatMap(UserID.init(validating:))
        let createdAt = Date(timeIntervalSince1970: TimeInterval(createdAt ?? 0))
        let childDTOs = children ?? []
        let childIDs = childDTOs.compactMap { dto in
            dto.id.flatMap(ItemID.init(validating:))
        }
        let domainURL = url.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let domainText = text.map(HTMLText.init)
        let parentID = parentID.flatMap(ItemID.init(validating:))

        let kind = type.flatMap(ItemKind.init(rawValue:))
        guard let kind else {
            return Item(
                id: id,
                author: author,
                createdAt: createdAt,
                flags: .deleted,
                content: .deleted(DeletedItem(parentID: parentID, childIDs: childIDs))
            )
        }

        let content: Item.Content
        switch kind {
        case .story:
            content = .story(
                Story(
                    title: HTMLText(title ?? ""),
                    url: domainURL,
                    text: domainText,
                    score: points ?? 0,
                    commentCount: isRoot ? childDTOs.reduce(0) { $0 + 1 + countChildren($1) } : 0,
                    commentIDs: childIDs
                )
            )

        case .comment:
            guard let parentID else {
                return Item(
                    id: id,
                    author: author,
                    createdAt: createdAt,
                    flags: .deleted,
                    content: .deleted(DeletedItem(parentID: nil, childIDs: childIDs))
                )
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
                    title: HTMLText(title ?? ""),
                    url: domainURL,
                    text: domainText,
                    score: points ?? 0
                )
            )

        case .poll:
            content = .poll(
                Poll(
                    title: HTMLText(title ?? ""),
                    text: domainText,
                    score: points ?? 0,
                    commentCount: isRoot ? childDTOs.reduce(0) { $0 + 1 + countChildren($1) } : 0,
                    commentIDs: childIDs,
                    optionIDs: []
                )
            )

        case .pollOption:
            guard let parentID else {
                return Item(
                    id: id,
                    author: author,
                    createdAt: createdAt,
                    flags: .deleted,
                    content: .deleted(DeletedItem(parentID: nil, childIDs: childIDs))
                )
            }
            content = .pollOption(
                PollOption(
                    pollID: parentID,
                    text: domainText ?? .empty,
                    score: points ?? 0
                )
            )
        }

        return Item(
            id: id,
            author: author,
            createdAt: createdAt,
            flags: [],
            content: content
        )
    }

    private func countChildren(_ dto: AlgoliaItemDTO) -> Int {
        (dto.children ?? []).reduce(0) { $0 + 1 + countChildren($1) }
    }
}

private func count(_ node: ThreadNode) -> Int {
    1 + node.replies.reduce(0) { $0 + count($1) }
}
