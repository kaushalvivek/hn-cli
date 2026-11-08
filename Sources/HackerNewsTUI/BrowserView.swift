import Foundation
import HackerNewsCore
import HackerNewsAdapters

@MainActor
public enum BrowserView {
    private struct Layout {
        let bodyY: Int
        let bodyHeight: Int
        let sidebar: Rect?
        let list: Rect
        let detail: Rect?
        let showDetail: Bool
    }

    public static func render(_ state: BrowserState, into screen: Screen) {
        state.screenWidth = screen.width
        state.screenHeight = screen.height
        state.hitRegions.removeAll(keepingCapacity: true)
        screen.clear()

        guard screen.height >= 6 else {
            screen.put("hn", x: 0, y: 0, style: Theme.accent)
            return
        }

        let layout = makeLayout(state: state, screen: screen)
        state.listViewportHeight = max(1, layout.list.height)
        state.detailViewportHeight = max(1, layout.detail?.height ?? 1)
        state.ensureSelectionVisible()

        drawHeader(state, screen)
        screen.hline(x: 0, y: 1, width: screen.width, style: Theme.border)
        drawBody(state, screen, layout: layout)
        screen.hline(x: 0, y: screen.height - 2, width: screen.width, style: Theme.border)
        drawFooter(state, screen)
        drawOverlay(state, screen, layout: layout)
    }

    // MARK: - Layout

    private static func makeLayout(state: BrowserState, screen: Screen) -> Layout {
        let bodyY = 2
        let bodyHeight = max(1, screen.height - 4)

        if state.isNarrow {
            let showDetail = state.focus == .detail
            let rect = Rect(x: 0, y: bodyY, width: screen.width, height: bodyHeight)
            return Layout(
                bodyY: bodyY,
                bodyHeight: bodyHeight,
                sidebar: nil,
                list: showDetail ? Rect(x: 0, y: bodyY, width: 0, height: bodyHeight) : rect,
                detail: showDetail ? rect : nil,
                showDetail: showDetail
            )
        }

        if !state.showSidebar {
            let listWidth = max(24, Int(Double(screen.width) * 0.44))
            let list = Rect(x: 0, y: bodyY, width: listWidth, height: bodyHeight)
            let detail = Rect(
                x: listWidth + 1,
                y: bodyY,
                width: screen.width - listWidth - 1,
                height: bodyHeight
            )
            return Layout(
                bodyY: bodyY,
                bodyHeight: bodyHeight,
                sidebar: nil,
                list: list,
                detail: detail,
                showDetail: true
            )
        }

        let sidebarWidth = min(22, max(16, screen.width / 5))
        let remaining = screen.width - sidebarWidth - 2
        var listWidth = max(24, Int(Double(remaining) * 0.42))
        var detailWidth = remaining - listWidth
        if detailWidth < 22 {
            let needed = 22 - detailWidth
            listWidth = max(20, listWidth - needed)
            detailWidth = remaining - listWidth
        }

        let sidebar = Rect(x: 0, y: bodyY, width: sidebarWidth, height: bodyHeight)
        let list = Rect(x: sidebarWidth + 1, y: bodyY, width: listWidth, height: bodyHeight)
        let detail = Rect(
            x: list.maxX + 1,
            y: bodyY,
            width: max(0, detailWidth),
            height: bodyHeight
        )

        return Layout(
            bodyY: bodyY,
            bodyHeight: bodyHeight,
            sidebar: sidebar,
            list: list,
            detail: detail,
            showDetail: true
        )
    }

    // MARK: - Header / footer

    private static func drawHeader(_ state: BrowserState, _ screen: Screen) {
        var left = StyledText()
        left.append("hn", style: Theme.accent)
        left.append("  /  ", style: Theme.muted)
        left.append(state.source.label, style: Theme.header)

        if case .thread(let threadView) = state.detail {
            left.append("  /  ", style: Theme.muted)
            left.append("item \(threadView.root.id)", style: Theme.muted)
        } else if case .loading(let id) = state.detail {
            left.append("  /  ", style: Theme.muted)
            left.append("loading \(id)", style: Theme.muted)
        }

        var user = StyledText()
        if let currentUser = state.currentUser {
            user.append("● ", style: Theme.success)
            user.append(currentUser.userID.rawValue, style: Theme.header)
        } else {
            user.append("○ not logged in", style: Theme.muted)
        }

        let rightWidth = user.width
        let leftWidth = max(0, screen.width - rightWidth - 2)
        screen.put(left.truncated(to: leftWidth), x: 1, y: 0, maxWidth: leftWidth)
        screen.put(user, x: max(1, screen.width - rightWidth - 1), y: 0)
    }

    private static func drawFooter(_ state: BrowserState, _ screen: Screen) {
        let mode: String
        let hints: String

        switch state.overlay {
        case .help:
            mode = "HELP"
            hints = "esc close"
        case .commands:
            mode = "COMMAND"
            hints = "type to filter · ↑↓ select · enter run · esc close"
        case .search:
            mode = "SEARCH"
            hints = "type query · enter search · esc cancel"
        case .login:
            mode = "LOGIN"
            hints = "tab switch field · enter log in · esc cancel"
        case .prompt:
            mode = "INPUT"
            hints = "enter submit · esc cancel"
        case .confirm:
            mode = "CONFIRM"
            hints = "y confirm · n cancel"
        case .compose:
            mode = "COMPOSE"
            hints = "ctrl-s post · esc save draft · ctrl-e editor"
        case .none:
            if state.focus == .sidebar {
                mode = "FEEDS"
                hints = "j/k feed · enter open · tab next · ? help"
            } else if state.focus == .detail {
                mode = "THREAD"
                hints = "j/k comments · space collapse · c reply · v vote · esc back"
            } else {
                mode = "BROWSE"
                hints = "j/k move · enter open · tab pane · / search · : commands · ? help · q quit"
            }
        }

        if screen.width < 80 {
            let shorter: String
            switch state.overlay {
            case .commands: shorter = "type · enter · esc"
            case .search: shorter = "enter search · esc"
            case .login: shorter = "tab · enter · esc"
            case .prompt: shorter = "enter · esc"
            case .confirm: shorter = "y/n"
            case .compose: shorter = "ctrl-s · esc · ctrl-e"
            case .help: shorter = "esc"
            case .none:
                switch state.focus {
                case .sidebar: shorter = "j/k · enter · tab"
                case .detail: shorter = "j/k · space · c · esc"
                case .list: shorter = "j/k · enter · / · ?"
                }
            }
            var line = StyledText()
            line.append(" \(mode) ", style: Theme.accent)
            line.append(" \(shorter)", style: Theme.muted)
            screen.put(line.truncated(to: screen.width - 1), x: 0, y: screen.height - 1)
        } else {
            var line = StyledText()
            line.append(" \(mode) ", style: Theme.accent)
            line.append(" \(hints)", style: Theme.muted)

            let right = footerRight(state).truncated(to: max(10, screen.width / 2))
            let rightWidth = right.width
            let leftWidth = max(0, screen.width - rightWidth - 1)
            screen.put(line.truncated(to: leftWidth), x: 0, y: screen.height - 1)
            screen.put(right, x: max(0, screen.width - rightWidth - 1), y: screen.height - 1)
        }
    }

    private static func footerRight(_ state: BrowserState) -> StyledText {
        var right = StyledText()

        if let toast = state.toast {
            let style: Style
            switch toast.style {
            case .info: style = Theme.muted
            case .success: style = Theme.success
            case .warning: style = Theme.warning
            case .error: style = Theme.error
            }
            right.append("\(toast.text) ", style: style)
        }

        if state.isBusy {
            right.append("\(state.spinner) ", style: Theme.accent)
        }

        if state.currentUser != nil {
            right.append("● ", style: Theme.success)
        } else {
            right.append("○ ", style: Theme.muted)
        }
        right.append(state.currentUserLabel, style: Theme.muted)
        right.append(" ", style: Theme.muted)
        return right
    }

    // MARK: - Body

    private static func drawBody(_ state: BrowserState, _ screen: Screen, layout: Layout) {
        state.listPaneRect = layout.list.width > 0 ? layout.list : nil
        state.detailPaneRect = layout.detail

        if let sidebar = layout.sidebar {
            drawSidebar(state, screen, rect: sidebar)
            for y in sidebar.y..<sidebar.maxY {
                screen.put("│", x: sidebar.maxX, y: y, style: Theme.border)
            }
        }

        if layout.list.width > 0 {
            drawList(state, screen, rect: layout.list)
        }

        if let detail = layout.detail {
            if layout.list.width > 0 {
                for y in detail.y..<detail.maxY {
                    screen.put("│", x: detail.x - 1, y: y, style: Theme.border)
                }
            }
            drawDetail(state, screen, rect: detail)
        }
    }

    private static func drawSidebar(_ state: BrowserState, _ screen: Screen, rect: Rect) {
        var y = rect.y
        var flatIndex = 0

        for section in state.sidebarSections {
            guard y < rect.maxY else { break }
            screen.put(section.title, x: rect.x + 1, y: y, style: Theme.muted)
            y += 1

            for source in section.items {
                guard y < rect.maxY else { break }
                let isCurrent = source == state.source
                let isSelected = flatIndex == state.selectedSourceIndex
                let active = state.focus == .sidebar && isSelected

                var line = StyledText()
                if active {
                    line.append("▸ ", style: Theme.accent)
                } else if isCurrent {
                    line.append("▸ ", style: Theme.accentPlain)
                } else {
                    line.append("  ", style: .plain)
                }

                if source.requiresAuthentication, state.currentUser == nil {
                    line.append(source.label, style: Theme.muted)
                    line.append("  login", style: Theme.muted)
                } else {
                    line.append(
                        source.label,
                        style: active ? Theme.selected : (isCurrent ? Theme.header : .plain)
                    )
                }

                let text = active || isCurrent ? line : line.restyled(Theme.muted)
                screen.put(text.truncated(to: rect.width - 2), x: rect.x, y: y, maxWidth: rect.width)
                state.hitRegions.append(
                    BrowserState.HitRegion(
                        rect: Rect(x: rect.x, y: y, width: rect.width, height: 1),
                        action: .source(flatIndex)
                    )
                )

                flatIndex += 1
                y += 1
            }
            y += 1
        }
    }

    private static func drawList(_ state: BrowserState, _ screen: Screen, rect: Rect) {
        guard rect.width > 4, rect.height > 1 else { return }

        var header = StyledText()
        header.append(state.source.label.uppercased(), style: Theme.accent)
        if !state.entries.isEmpty {
            header.append("  \(state.entries.count)", style: Theme.muted)
        }
        if state.isLoadingFeed || state.isLoadingMore {
            header.append("  \(state.spinner) loading", style: Theme.muted)
        }
        screen.put(header.truncated(to: rect.width), x: rect.x, y: rect.y, maxWidth: rect.width)
        screen.hline(
            x: rect.x,
            y: rect.y + 1,
            width: rect.width,
            style: Theme.border
        )

        let contentRect = Rect(
            x: rect.x,
            y: rect.y + 2,
            width: rect.width,
            height: rect.height - 2
        )
        state.listViewportHeight = max(1, contentRect.height)

        guard !state.entries.isEmpty else {
            if state.isLoadingFeed {
                screen.put(
                    StyledText("\(state.spinner) loading…", style: Theme.muted),
                    x: rect.x + 1,
                    y: contentRect.y + 1
                )
            } else {
                screen.put(
                    StyledText("Nothing here.", style: Theme.muted),
                    x: rect.x + 1,
                    y: contentRect.y + 1
                )
            }
            return
        }

        let visibleEntries = max(1, contentRect.height / 2)
        var start = min(state.listScroll, max(0, state.entries.count - 1))
        if state.selectedEntryIndex < start {
            start = state.selectedEntryIndex
        } else if state.selectedEntryIndex >= start + visibleEntries {
            start = state.selectedEntryIndex - visibleEntries + 1
        }
        start = max(0, start)

        var y = contentRect.y
        var index = start
        while index < state.entries.count, y + 1 < contentRect.maxY {
            let entry = state.entries[index]
            let selected = index == state.selectedEntryIndex
            let focused = selected && state.focus == .list
            let read = state.readIDs.contains(entry.id)

            drawEntryRow(
                state: state,
                entry: entry,
                index: index,
                selected: selected,
                focused: focused,
                read: read,
                screen: screen,
                x: rect.x,
                y: y,
                width: rect.width
            )

            state.hitRegions.append(
                BrowserState.HitRegion(
                    rect: Rect(x: rect.x, y: y, width: rect.width, height: 2),
                    action: .entry(index)
                )
            )

            y += 2
            index += 1
        }

        if state.isLoadingMore, y < contentRect.maxY {
            screen.put(
                StyledText("\(state.spinner) loading more…", style: Theme.muted),
                x: rect.x + 2,
                y: y
            )
        }
    }

    private static func drawEntryRow(
        state: BrowserState,
        entry: TUIEntry,
        index: Int,
        selected: Bool,
        focused: Bool,
        read: Bool,
        screen: Screen,
        x: Int,
        y: Int,
        width: Int
    ) {
        let contentWidth = max(1, width - 2)
        var title = StyledText()

        switch entry.kind {
        case .comment:
            title.append("\(index + 1). ", style: Theme.muted)
            title.append(entry.author?.rawValue ?? "[deleted]", style: Theme.link)
            title.append(" · \(TUIText.relativeTime(entry.createdAt))", style: Theme.muted)
        case .deleted:
            title.append("\(index + 1). ", style: Theme.muted)
            title.append("[deleted]", style: Theme.muted)
        default:
            title.append("\(index + 1). ", style: Theme.muted)
            title.append(
                entry.displayTitle,
                style: read ? Theme.muted : Theme.header
            )
        }

        var meta = StyledText()
        if entry.kind == .comment {
            if let storyTitle = entry.storyTitle {
                meta.append("on \(storyTitle) · ", style: Theme.muted)
            }
            if let text = entry.text {
                meta.append(text.replacingOccurrences(of: "\n", with: " "), style: Theme.muted)
            } else {
                meta.append("[deleted]", style: Theme.muted)
            }
        } else {
            if let domain = entry.domain {
                meta.append(domain, style: Theme.muted)
                meta.append(" · ", style: Theme.muted)
            }
            if let score = entry.score {
                meta.append("\(score) points", style: Theme.muted)
                meta.append(" · ", style: Theme.muted)
            }
            if let comments = entry.commentCount {
                meta.append("\(comments) comments", style: Theme.muted)
                meta.append(" · ", style: Theme.muted)
            }
            if let author = entry.author {
                meta.append(author.rawValue, style: Theme.muted)
                meta.append(" · ", style: Theme.muted)
            }
            meta.append(TUIText.relativeTime(entry.createdAt), style: Theme.muted)
        }

        let bar: String
        let barStyle: Style
        if selected {
            bar = "▌"
            barStyle = focused ? Theme.accent : Theme.accentPlain
        } else {
            bar = " "
            barStyle = .plain
        }

        screen.put(bar, x: x, y: y, style: barStyle)
        screen.put(bar, x: x, y: y + 1, style: barStyle)

        if focused {
            screen.put(title.restyled(Theme.selected).truncated(to: contentWidth), x: x + 2, y: y)
            screen.put(meta.restyled(Theme.selected).truncated(to: contentWidth), x: x + 2, y: y + 1)
        } else {
            screen.put(title.truncated(to: contentWidth), x: x + 2, y: y)
            screen.put(meta.truncated(to: contentWidth), x: x + 2, y: y + 1)
        }
    }

    private static func drawDetail(_ state: BrowserState, _ screen: Screen, rect: Rect) {
        guard rect.width > 4, rect.height > 0 else { return }

        switch state.detail {
        case .empty:
            screen.put(
                StyledText("Select a story to read it.", style: Theme.muted),
                x: rect.x + 1,
                y: rect.y + 1
            )

        case .preview(let entry):
            drawEntryPreview(state, screen, rect: rect, entry: entry)

        case .loading(let id):
            var line = StyledText()
            line.append("\(state.spinner) ", style: Theme.accent)
            line.append("Loading thread \(id)…", style: Theme.muted)
            screen.put(line, x: rect.x + 1, y: rect.y + 1)

        case .error(let id, let message):
            var line = StyledText()
            line.append("Could not load item \(id)", style: Theme.error)
            screen.put(line, x: rect.x + 1, y: rect.y + 1)
            screen.put(
                StyledText(message, style: Theme.muted),
                x: rect.x + 1,
                y: rect.y + 2
            )
            screen.put(
                StyledText("r to retry · esc back", style: Theme.muted),
                x: rect.x + 1,
                y: rect.y + 4
            )

        case .thread(let threadView):
            drawThread(state, screen, rect: rect, threadView: threadView)
        }
    }

    private static func drawEntryPreview(
        _ state: BrowserState,
        _ screen: Screen,
        rect: Rect,
        entry: TUIEntry
    ) {
        var y = rect.y
        let width = rect.width - 2
        let x = rect.x + 1

        let title = StyledText(entry.displayTitle, style: Theme.header)
        for line in wrappedLines(title, width: width) {
            guard y < rect.maxY else { return }
            screen.put(line, x: x, y: y)
            y += 1
        }

        if let url = entry.url, y < rect.maxY {
            screen.put(
                StyledText(url.absoluteString, style: Theme.link),
                x: x,
                y: y
            )
            y += 1
        }

        if y < rect.maxY {
            var meta = StyledText()
            if let domain = entry.domain {
                meta.append(domain, style: Theme.muted)
                meta.append(" · ", style: Theme.muted)
            }
            if let score = entry.score {
                meta.append("\(score) points", style: Theme.muted)
                meta.append(" · ", style: Theme.muted)
            }
            if let comments = entry.commentCount {
                meta.append("\(comments) comments", style: Theme.muted)
                meta.append(" · ", style: Theme.muted)
            }
            if let author = entry.author {
                meta.append(author.rawValue, style: Theme.muted)
                meta.append(" · ", style: Theme.muted)
            }
            meta.append(TUIText.relativeTime(entry.createdAt), style: Theme.muted)
            meta.append(" · id \(entry.id)", style: Theme.muted)
            screen.put(meta.truncated(to: width), x: x, y: y)
            y += 1
        }

        if let text = entry.text, !text.isEmpty {
            y += 1
            for line in TUIText.wrap(text, width: width) {
                guard y < rect.maxY else { return }
                screen.put(StyledText(line), x: x, y: y)
                y += 1
            }
        }

        if state.isLoadingThread, y < rect.maxY {
            var line = StyledText()
            line.append("\(state.spinner) ", style: Theme.accent)
            line.append("loading comments…", style: Theme.muted)
            screen.put(line, x: x, y: y)
            y += 1
        }

        y += 1
        if y < rect.maxY {
            screen.put(
                StyledText("enter open comments · o open link · y copy · c reply", style: Theme.muted),
                x: x,
                y: y
            )
        }
    }

    private static func drawThread(
        _ state: BrowserState,
        _ screen: Screen,
        rect: Rect,
        threadView: TUIThread
    ) {
        var y = rect.y
        let x = rect.x + 1
        let width = rect.width - 2

        let root = threadView.root
        let rootEntry = TUIEntry(item: root)

        switch root.content {
        case .comment:
            var header = StyledText()
            header.append(root.author?.rawValue ?? "[deleted]", style: Theme.link)
            header.append(" · \(TUIText.relativeTime(root.createdAt)) · \(root.id)", style: Theme.muted)
            if root.isDead { header.append("  dead", style: Theme.warning) }
            screen.put(header.truncated(to: width), x: x, y: y)
            y += 1
            if let text = Format.text(for: root) {
                for line in TUIText.wrap(text, width: width) {
                    guard y < rect.maxY else { return }
                    screen.put(StyledText(line), x: x, y: y)
                    y += 1
                }
            }
        default:
            for line in wrappedLines(
                StyledText(rootEntry.displayTitle, style: Theme.header),
                width: width
            ) {
                guard y < rect.maxY else { return }
                screen.put(line, x: x, y: y)
                y += 1
            }
            if let url = rootEntry.url, y < rect.maxY {
                screen.put(StyledText(url.absoluteString, style: Theme.link), x: x, y: y)
                y += 1
            }
            if y < rect.maxY {
                var meta = StyledText()
                if let score = rootEntry.score {
                    meta.append("\(score) points", style: Theme.muted)
                    meta.append(" · ", style: Theme.muted)
                }
                if let comments = rootEntry.commentCount {
                    meta.append("\(comments) comments", style: Theme.muted)
                    meta.append(" · ", style: Theme.muted)
                }
                if let author = rootEntry.author {
                    meta.append(author.rawValue, style: Theme.muted)
                    meta.append(" · ", style: Theme.muted)
                }
                meta.append(TUIText.relativeTime(root.createdAt), style: Theme.muted)
                meta.append(" · id \(root.id)", style: Theme.muted)
                screen.put(meta.truncated(to: width), x: x, y: y)
                y += 1
            }
            if let text = rootEntry.text, !text.isEmpty {
                y += 1
                for line in TUIText.wrap(text, width: width) {
                    guard y < rect.maxY else { return }
                    screen.put(StyledText(line), x: x, y: y)
                    y += 1
                }
            }
        }

        y += 1
        if y < rect.maxY {
            screen.hline(x: x, y: y, width: width, style: Theme.border)
            y += 1
        }

        if threadView.visible.isEmpty {
            if y < rect.maxY {
                screen.put(StyledText("No comments yet.", style: Theme.muted), x: x, y: y)
            }
            return
        }

        let available = max(1, rect.maxY - y)
        adjustThreadStart(threadView, availableHeight: available, width: width)

        var commentIndex = threadView.startIndex
        while commentIndex < threadView.visible.count, y < rect.maxY {
            let comment = threadView.visible[commentIndex]
            let selected = commentIndex == threadView.selectedIndex
            let startY = y
            y = drawComment(
                comment,
                selected: selected,
                spinner: state.spinner,
                screen: screen,
                x: x,
                y: y,
                width: width,
                maxY: rect.maxY
            )
            state.hitRegions.append(
                BrowserState.HitRegion(
                    rect: Rect(x: rect.x, y: startY, width: rect.width, height: max(1, y - startY)),
                    action: .comment(commentIndex)
                )
            )
            commentIndex += 1
        }
    }

    private static func adjustThreadStart(
        _ thread: TUIThread,
        availableHeight: Int,
        width: Int
    ) {
        guard !thread.visible.isEmpty else { return }
        thread.startIndex = min(max(0, thread.startIndex), thread.visible.count - 1)

        if thread.selectedIndex < thread.startIndex {
            thread.startIndex = thread.selectedIndex
        }

        func height(_ index: Int) -> Int {
            let comment = thread.visible[index]
            let node = comment.node
            let indent = comment.depth * 2
            let textWidth = max(10, width - indent - 4)
            var h = 1
            if !node.item.isDeleted, let text = Format.text(for: node.item) {
                h += TUIText.wrap(text, width: textWidth).count
            }
            if node.hasChildren {
                h += 1
            }
            h += 1
            return h
        }

        while thread.startIndex < thread.selectedIndex {
            var total = 0
            for index in thread.startIndex...thread.selectedIndex {
                total += height(index)
            }
            if total <= availableHeight { break }
            thread.startIndex += 1
        }

        if thread.startIndex > thread.selectedIndex {
            thread.startIndex = thread.selectedIndex
        }
    }

    private static func drawComment(
        _ comment: TUIThread.Visible,
        selected: Bool,
        spinner: String,
        screen: Screen,
        x: Int,
        y: Int,
        width: Int,
        maxY: Int
    ) -> Int {
        var y = y
        let indent = comment.depth * 2
        let textWidth = max(10, width - indent - 4)
        let bar = selected ? "▌" : " "
        let barStyle = selected ? Theme.accent : Style.plain
        let textBar = selected ? "│" : " "
        let textBarStyle = selected ? Theme.border : Style.plain
        let prefix = String(repeating: "  ", count: comment.depth)
        let node = comment.node

        guard y < maxY else { return y }

        var header = StyledText()
        header.append(prefix, style: Theme.muted)
        header.append(bar, style: barStyle)
        header.append(" ", style: .plain)

        if node.item.isDeleted {
            header.append("[deleted]", style: Theme.muted)
        } else {
            header.append(node.item.author?.rawValue ?? "[deleted]", style: Theme.link)
            header.append(" · \(TUIText.relativeTime(node.item.createdAt))", style: Theme.muted)
            header.append(" · \(node.id)", style: Theme.muted)
            if node.item.isDead {
                header.append("  dead", style: Theme.warning)
            }
        }

        if node.hasChildren {
            if node.isLoading {
                header.append("  \(spinner)", style: Theme.accent)
            } else if node.isExpanded {
                header.append("  ▾", style: Theme.muted)
            } else {
                header.append("  ▸", style: Theme.muted)
            }
        }

        screen.put(header.truncated(to: width), x: x, y: y)
        y += 1

        if !node.item.isDeleted, let text = Format.text(for: node.item) {
            for line in TUIText.wrap(text, width: textWidth) {
                guard y < maxY else { return y }
                var lineText = StyledText()
                lineText.append(prefix, style: Theme.muted)
                lineText.append(textBar, style: textBarStyle)
                lineText.append(" ", style: .plain)
                lineText.append(line, style: .plain)
                screen.put(lineText.truncated(to: width), x: x, y: y)
                y += 1
            }
        }

        if node.hasChildren, node.isLoading {
            if y < maxY {
                screen.put(
                    StyledText(prefix + "  \(spinner) loading replies…", style: Theme.muted),
                    x: x,
                    y: y
                )
                y += 1
            }
        } else if node.hasChildren, !node.isExpanded {
            if y < maxY {
                let count = node.item.childIDs.count
                screen.put(
                    StyledText(prefix + "  ▸ \(count) replies · enter to expand", style: Theme.muted),
                    x: x,
                    y: y
                )
                y += 1
            }
        }

        if y < maxY {
            screen.put("", x: x, y: y)
            y += 1
        }

        return y
    }

    // MARK: - Overlays

    private static func drawOverlay(_ state: BrowserState, _ screen: Screen, layout: Layout) {
        guard let overlay = state.overlay else { return }

        // Modal scrim: hide the feed/list/detail content behind the overlay so
        // stray text at the edges cannot visually collide with the modal.
        screen.fill(
            Rect(
                x: 0,
                y: layout.bodyY,
                width: screen.width,
                height: layout.bodyHeight
            ),
            style: .plain
        )

        switch overlay {
        case .help:
            let rect = centeredRect(
                width: min(78, screen.width - 4),
                height: min(24, layout.bodyHeight - 2),
                screen: screen,
                bodyY: layout.bodyY,
                bodyHeight: layout.bodyHeight
            )
            drawBox(screen, rect, title: "Keyboard")
            drawHelp(screen, rect: rect.inset(by: 1))

        case .commands(let palette):
            let rect = centeredRect(
                width: min(78, screen.width - 4),
                height: min(18, layout.bodyHeight - 2),
                screen: screen,
                bodyY: layout.bodyY,
                bodyHeight: layout.bodyHeight
            )
            drawBox(screen, rect, title: "Commands")
            drawCommandPalette(state, palette, screen, rect: rect.inset(by: 1))

        case .search(let palette):
            let rect = centeredRect(
                width: min(70, screen.width - 4),
                height: 5,
                screen: screen,
                bodyY: layout.bodyY,
                bodyHeight: layout.bodyHeight
            )
            drawBox(screen, rect, title: "Search")
            drawInput(
                label: "/",
                text: palette.query,
                placeholder: "search Hacker News",
                focused: true,
                masked: false,
                screen: screen,
                x: rect.x + 2,
                y: rect.y + 2,
                width: rect.width - 4
            )

        case .login(let form):
            let rect = centeredRect(
                width: min(58, screen.width - 4),
                height: 10,
                screen: screen,
                bodyY: layout.bodyY,
                bodyHeight: layout.bodyHeight
            )
            drawBox(screen, rect, title: "Log in")
            drawInput(
                label: "user",
                text: form.username,
                placeholder: "username",
                focused: form.focusedField == 0,
                masked: false,
                screen: screen,
                x: rect.x + 2,
                y: rect.y + 2,
                width: rect.width - 4
            )
            drawInput(
                label: "pass",
                text: form.password,
                placeholder: "password",
                focused: form.focusedField == 1,
                masked: true,
                screen: screen,
                x: rect.x + 2,
                y: rect.y + 4,
                width: rect.width - 4
            )
            if let error = form.error {
                screen.put(
                    StyledText(error, style: Theme.error).truncated(to: rect.width - 4),
                    x: rect.x + 2,
                    y: rect.y + 6
                )
            } else if form.isSubmitting {
                screen.put(
                    StyledText("logging in…", style: Theme.muted),
                    x: rect.x + 2,
                    y: rect.y + 6
                )
            }
            screen.put(
                StyledText("tab switch · enter log in · esc cancel", style: Theme.muted),
                x: rect.x + 2,
                y: rect.maxY - 2
            )

        case .prompt(let prompt):
            let rect = centeredRect(
                width: min(68, screen.width - 4),
                height: 6,
                screen: screen,
                bodyY: layout.bodyY,
                bodyHeight: layout.bodyHeight
            )
            drawBox(screen, rect, title: prompt.title)
            drawInput(
                label: "›",
                text: prompt.text,
                placeholder: prompt.placeholder,
                focused: true,
                masked: false,
                screen: screen,
                x: rect.x + 2,
                y: rect.y + 2,
                width: rect.width - 4
            )
            screen.put(
                StyledText("enter submit · esc cancel", style: Theme.muted),
                x: rect.x + 2,
                y: rect.maxY - 2
            )

        case .confirm(let confirm):
            let rect = centeredRect(
                width: min(60, screen.width - 4),
                height: 6,
                screen: screen,
                bodyY: layout.bodyY,
                bodyHeight: layout.bodyHeight
            )
            drawBox(screen, rect, title: "Confirm")
            screen.put(
                StyledText(confirm.message, style: Theme.header).truncated(to: rect.width - 4),
                x: rect.x + 2,
                y: rect.y + 2
            )
            screen.put(
                StyledText("y confirm · n cancel", style: Theme.muted),
                x: rect.x + 2,
                y: rect.maxY - 2
            )

        case .compose(let compose):
            drawCompose(state, compose, screen, layout: layout)
        }
    }

    private static func drawCompose(
        _ state: BrowserState,
        _ compose: ComposeState,
        _ screen: Screen,
        layout: Layout
    ) {
        let width = min(100, max(30, screen.width - 4))
        let height = min(30, max(14, layout.bodyHeight - 2))
        let rect = centeredRect(
            width: width,
            height: height,
            screen: screen,
            bodyY: layout.bodyY,
            bodyHeight: layout.bodyHeight
        )
        drawBox(screen, rect, title: compose.kind.title)

        let inner = rect.inset(by: 1)
        var compose = compose
        var y = inner.y

        var contextLine = StyledText()
        contextLine.append(compose.context.label + " ", style: Theme.accent)
        if let author = compose.context.author {
            contextLine.append(author.rawValue, style: Theme.link)
        }
        if let storyTitle = compose.context.storyTitle, !storyTitle.isEmpty {
            contextLine.append(" · " + storyTitle, style: Theme.muted)
        }
        screen.put(contextLine.truncated(to: inner.width), x: inner.x, y: y)
        y += 1

        if let excerpt = compose.context.excerpt, !excerpt.isEmpty, y < inner.maxY - 8 {
            let quote = excerpt
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for line in TUIText.wrap("> " + quote, width: inner.width).prefix(2) {
                screen.put(StyledText(line, style: Theme.muted), x: inner.x, y: y)
                y += 1
            }
        }

        if compose.restoredDraft, y < inner.maxY - 8 {
            screen.put(
                StyledText("draft restored", style: Theme.warning),
                x: inner.x,
                y: y
            )
            y += 1
        }

        screen.hline(x: inner.x, y: y, width: inner.width, style: Theme.border)
        y += 1

        let statusY = inner.maxY - 2
        let hintY = inner.maxY - 1
        let textTop = y
        let textBottom = statusY - 1
        let textHeight = max(1, textBottom - textTop + 1)
        let layoutText = ComposeLayoutBuilder.build(text: compose.text, width: inner.width)
        let maxScroll = max(0, layoutText.lines.count - 1)
        var scroll = min(max(0, compose.scroll), maxScroll)
        if layoutText.cursorLine < scroll {
            scroll = layoutText.cursorLine
        } else if layoutText.cursorLine >= scroll + textHeight {
            scroll = layoutText.cursorLine - textHeight + 1
        }
        scroll = max(0, min(scroll, maxScroll))
        compose.scroll = scroll

        let characters = Array(compose.text)
        for index in scroll..<min(layoutText.lines.count, scroll + textHeight) {
            let line = layoutText.lines[index]
            let row = textTop + index - scroll
            screen.put(StyledText(line.text), x: inner.x, y: row, maxWidth: inner.width)

            if index == layoutText.cursorLine {
                let cursorX = min(inner.x + layoutText.cursorColumn, inner.maxX - 1)
                let cursorCharacter: String
                if compose.cursor < characters.count, characters[compose.cursor] != "\n" {
                    cursorCharacter = String(characters[compose.cursor])
                } else {
                    cursorCharacter = " "
                }
                screen.put(
                    cursorCharacter,
                    x: cursorX,
                    y: row,
                    style: Style(reverse: true),
                    maxWidth: 1
                )
            }
        }

        if compose.isSubmitting {
            var status = StyledText()
            status.append("\(state.spinner) posting…", style: Theme.accent)
            screen.put(status, x: inner.x, y: statusY)
        } else if let error = compose.error {
            screen.put(
                StyledText(error, style: Theme.error).truncated(to: inner.width),
                x: inner.x,
                y: statusY
            )
        } else {
            var status = StyledText()
            status.append("\(compose.characterCount) chars", style: Theme.muted)
            if compose.restoredDraft {
                status.append(" · draft restored", style: Theme.warning)
            }
            screen.put(status, x: inner.x, y: statusY)
        }

        let submitKey = compose.kind.submitLabel
        screen.put(
            StyledText(
                "ctrl-s \(submitKey) · esc save draft · ctrl-e external editor",
                style: Theme.muted
            ),
            x: inner.x,
            y: hintY,
            maxWidth: inner.width
        )

        if compose.scroll != (state.overlay.flatMap { overlay -> Int? in
            if case .compose(let current) = overlay { return current.scroll }
            return nil
        } ?? -1) {
            state.overlay = .compose(compose)
        }
    }

    private static func drawCommandPalette(
        _ state: BrowserState,
        _ palette: BrowserState.CommandPalette,
        _ screen: Screen,
        rect: Rect
    ) {
        drawInput(
            label: "›",
            text: palette.query,
            placeholder: "type a command",
            focused: true,
            masked: false,
            screen: screen,
            x: rect.x,
            y: rect.y,
            width: rect.width
        )
        screen.hline(x: rect.x, y: rect.y + 1, width: rect.width, style: Theme.border)

        let commands = state.filteredCommands
        guard !commands.isEmpty else {
            screen.put(
                StyledText("No matching commands", style: Theme.muted),
                x: rect.x + 1,
                y: rect.y + 3
            )
            return
        }

        var y = rect.y + 2
        let selected = min(palette.selectedIndex, commands.count - 1)
        let start = max(0, min(selected - (rect.height - 4), selected))
        for index in start..<commands.count {
            guard y < rect.maxY else { break }
            let command = commands[index]
            var line = StyledText()
            line.append(command.title, style: index == selected ? Theme.selected : .plain)
            if let subtitle = command.subtitle {
                line.append("  \(subtitle)", style: index == selected ? Theme.selected : Theme.muted)
            }
            if index == selected {
                line = line.restyled(Theme.selected)
            }
            screen.put(line.truncated(to: rect.width - 1), x: rect.x, y: y)
            y += 1
        }
    }

    private static func drawHelp(_ screen: Screen, rect: Rect) {
        let entries: [(String, String)] = [
            ("j / k, ↑ / ↓", "move"),
            ("g / G", "top / bottom"),
            ("enter / l", "open"),
            ("tab", "next pane"),
            ("esc / h", "back"),
            ("space", "collapse comment"),
            ("/", "search"),
            (":  ctrl-p", "commands"),
            ("r", "refresh"),
            ("o / y", "open / copy URL"),
            ("v / V / u", "upvote / downvote / unvote"),
            ("f / F", "favorite / unfavorite"),
            ("H / U", "hide / unhide"),
            ("! ", "flag"),
            ("c / e / d", "comment / edit / delete"),
            ("s", "submit story"),
            ("L", "log in"),
            ("?", "this help"),
            ("q / ctrl-c", "quit"),
        ]

        let columnWidth = max(20, rect.width / 2)
        var leftY = rect.y
        var rightY = rect.y
        for (index, entry) in entries.enumerated() {
            let y = index < 10 ? leftY : rightY
            let x = index < 10 ? rect.x : rect.x + columnWidth
            var key = StyledText(entry.0, style: Theme.accent)
            key.append("  " + entry.1, style: Theme.muted)
            screen.put(key.truncated(to: columnWidth - 1), x: x, y: y)
            if index < 10 { leftY += 1 } else { rightY += 1 }
        }
    }

    private static func drawInput(
        label: String,
        text: String,
        placeholder: String,
        focused: Bool,
        masked: Bool,
        screen: Screen,
        x: Int,
        y: Int,
        width: Int
    ) {
        var line = StyledText()
        line.append("\(label) ", style: focused ? Theme.accent : Theme.muted)
        let display = masked ? String(repeating: "•", count: text.count) : text
        if display.isEmpty, !placeholder.isEmpty {
            line.append(placeholder, style: Theme.muted)
        } else {
            line.append(display, style: focused ? Theme.header : .plain)
        }
        if focused {
            line.append("▌", style: Theme.accent)
        }
        screen.put(line.truncated(to: width), x: x, y: y)
    }

    private static func drawBox(_ screen: Screen, _ rect: Rect, title: String) {
        screen.fill(rect, style: .plain)
        screen.drawBox(rect, style: Theme.border)
        guard rect.width > title.count + 6 else { return }
        screen.put(
            StyledText(" \(title) ", style: Theme.accent),
            x: rect.x + 2,
            y: rect.y
        )
    }

    private static func centeredRect(
        width: Int,
        height: Int,
        screen: Screen,
        bodyY: Int,
        bodyHeight: Int
    ) -> Rect {
        let w = max(10, min(width, screen.width - 2))
        let h = max(4, min(height, bodyHeight - 2))
        return Rect(
            x: max(0, (screen.width - w) / 2),
            y: bodyY + max(0, (bodyHeight - h) / 2),
            width: w,
            height: h
        )
    }

    private static func wrappedLines(_ text: StyledText, width: Int) -> [StyledText] {
        let plain = text.plainText
        let lines = TUIText.wrap(plain, width: width)
        return lines.map { StyledText($0, style: text.spans.first?.style ?? .plain) }
    }
}

private enum Format {
    static func text(for item: Item) -> String? {
        guard let text = item.text else { return nil }
        let rendered = HTMLTextRenderer.plainText(text.rawHTML)
        return rendered.isEmpty ? nil : rendered
    }
}
