import Foundation
import HackerNewsCore

@MainActor
final class TUICommentNode {
    var item: Item
    var replies: [TUICommentNode]?
    var isExpanded: Bool
    var isLoading: Bool

    init(item: Item, replies: [TUICommentNode]? = nil, isExpanded: Bool = false) {
        self.item = item
        self.replies = replies
        self.isExpanded = isExpanded
        self.isLoading = false
    }

    var id: ItemID { item.id }
    var hasChildren: Bool { !item.childIDs.isEmpty }
    var isLoaded: Bool { replies != nil }
}

@MainActor
public final class TUIThread {
    struct Visible {
        let node: TUICommentNode
        let depth: Int
    }

    let root: Item
    var topLevel: [TUICommentNode]
    var visible: [Visible] = []
    var selectedIndex = 0
    var startIndex = 0

    init(root: Item, topLevel: [TUICommentNode]) {
        self.root = root
        self.topLevel = topLevel
        rebuild()
    }

    var selectedNode: TUICommentNode? {
        guard visible.indices.contains(selectedIndex) else { return nil }
        return visible[selectedIndex].node
    }

    func rebuild() {
        var result: [Visible] = []

        func walk(_ nodes: [TUICommentNode], depth: Int) {
            for node in nodes {
                result.append(Visible(node: node, depth: depth))
                if node.isExpanded, let replies = node.replies {
                    walk(replies, depth: depth + 1)
                }
            }
        }

        walk(topLevel, depth: 0)
        visible = result
        selectedIndex = min(selectedIndex, max(0, visible.count - 1))
        startIndex = min(startIndex, max(0, visible.count - 1))
    }

    func makeChildren(from nodes: [ThreadNode]) -> [TUICommentNode] {
        nodes.map { node in
            TUICommentNode(
                item: node.item,
                replies: node.item.childIDs.isEmpty ? [] : nil
            )
        }
    }

    @discardableResult
    func insert(_ item: Item, under parentID: ItemID) -> Bool {
        let newNode = TUICommentNode(item: item, replies: item.childIDs.isEmpty ? [] : nil)

        if parentID == root.id {
            topLevel.append(newNode)
            rebuild()
            select(id: item.id)
            return true
        }

        func find(_ node: TUICommentNode) -> TUICommentNode? {
            if node.id == parentID { return node }
            for reply in node.replies ?? [] {
                if let found = find(reply) { return found }
            }
            return nil
        }

        guard let parent = topLevel.compactMap({ find($0) }).first else {
            return false
        }
        if parent.replies == nil { parent.replies = [] }
        parent.replies?.append(newNode)
        parent.isExpanded = true
        rebuild()
        select(id: item.id)
        return true
    }

    func select(id: ItemID) {
        if let index = visible.firstIndex(where: { $0.node.id == id }) {
            selectedIndex = index
            ensureSelection(startIndex: &startIndex, selectedIndex: selectedIndex)
        }
    }

    @discardableResult
    func updateText(id: ItemID, text: String) -> Bool {
        func find(_ node: TUICommentNode) -> TUICommentNode? {
            if node.id == id { return node }
            for reply in node.replies ?? [] {
                if let found = find(reply) { return found }
            }
            return nil
        }

        guard let node = topLevel.compactMap({ find($0) }).first else {
            return false
        }
        node.item = node.item.updatingText(text)
        rebuild()
        return true
    }

    private func ensureSelection(startIndex: inout Int, selectedIndex: Int) {
        if selectedIndex < startIndex {
            startIndex = selectedIndex
        }
    }
}

private extension Item {
    func updatingText(_ text: String) -> Item {
        let content: Item.Content
        switch self.content {
        case .story(let story):
            content = .story(
                Story(
                    title: story.title,
                    url: story.url,
                    text: HTMLText(text),
                    score: story.score,
                    commentCount: story.commentCount,
                    commentIDs: story.commentIDs
                )
            )
        case .comment(let comment):
            content = .comment(
                Comment(
                    parentID: comment.parentID,
                    text: HTMLText(text),
                    childIDs: comment.childIDs
                )
            )
        case .job(let job):
            content = .job(
                Job(
                    title: job.title,
                    url: job.url,
                    text: HTMLText(text),
                    score: job.score
                )
            )
        case .poll(let poll):
            content = .poll(
                Poll(
                    title: poll.title,
                    text: HTMLText(text),
                    score: poll.score,
                    commentCount: poll.commentCount,
                    commentIDs: poll.commentIDs,
                    optionIDs: poll.optionIDs
                )
            )
        case .pollOption(let option):
            content = .pollOption(
                PollOption(
                    pollID: option.pollID,
                    text: HTMLText(text),
                    score: option.score
                )
            )
        case .deleted:
            content = self.content
        }

        return Item(
            id: id,
            author: author,
            createdAt: createdAt,
            flags: flags,
            content: content
        )
    }
}
