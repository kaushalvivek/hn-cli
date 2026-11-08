import Foundation
import HackerNewsCore

@MainActor
final class TUICommentNode {
    let item: Item
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
}
