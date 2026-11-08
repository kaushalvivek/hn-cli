import Foundation
import HackerNewsCore
import HackerNewsAdapters

@MainActor
public final class BrowserState {
    public enum Focus: Equatable, Sendable {
        case sidebar
        case list
        case detail
    }

    public enum ToastStyle: Sendable {
        case info
        case success
        case warning
        case error
    }

    public struct Toast: Sendable {
        public let text: String
        public let style: ToastStyle
        public let expiresAt: Date
    }

    public enum Detail {
        case empty
        case preview(TUIEntry)
        case loading(ItemID)
        case thread(TUIThread)
        case error(ItemID, String)
    }

    public struct FeedCache {
        public var entries: [TUIEntry]
        public var hasMore: Bool
        public var selectedIndex: Int
        public var scroll: Int
    }

    public struct CommandPalette: Equatable, Sendable {
        public var query: String
        public var selectedIndex: Int
    }

    public struct SearchPalette: Equatable, Sendable {
        public var query: String
    }

    public struct LoginForm: Equatable, Sendable {
        public var username: String
        public var password: String
        public var focusedField: Int
        public var error: String?
        public var isSubmitting: Bool
    }

    public enum PromptKind: Equatable, Sendable {
        case fromSite
        case pastDate
        case flagReason
        case submitTitle
        case submitURL
    }

    public struct Prompt: Equatable, Sendable {
        public var title: String
        public var placeholder: String
        public var text: String
        public var kind: PromptKind
    }

    public enum ConfirmKind: Equatable, Sendable {
        case delete(ItemID)
        case logout
        case quit
    }

    public struct Confirm: Equatable, Sendable {
        public let message: String
        public let kind: ConfirmKind
    }

    public enum Overlay: Equatable, Sendable {
        case help
        case commands(CommandPalette)
        case search(SearchPalette)
        case login(LoginForm)
        case prompt(Prompt)
        case confirm(Confirm)
    }

    public enum CommandAction: Sendable {
        case source(Source)
        case search
        case login
        case logout
        case refresh
        case submit
        case fromSite
        case past
        case help
        case quit
    }

    public struct TUICommand: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let subtitle: String?
        public let keywords: String
        public let action: CommandAction
    }

    public enum EditorRequest: Sendable {
        case comment(parent: ItemID)
        case edit(id: ItemID, initialText: String)
        case submitText(title: String)
    }

    public struct HitRegion: Sendable {
        public let rect: Rect
        public let action: HitAction

        public init(rect: Rect, action: HitAction) {
            self.rect = rect
            self.action = action
        }
    }

    public enum HitAction: Sendable {
        case source(Int)
        case entry(Int)
        case comment(Int)
    }

    // MARK: - State

    public let client: HackerNewsClient
    public private(set) var sidebarSections: [SidebarSection]
    public private(set) var sidebarSources: [Source]

    public var selectedSourceIndex: Int
    public var source: Source
    public var entries: [TUIEntry] = []
    public var selectedEntryIndex: Int = 0
    public var listScroll: Int = 0
    public var focus: Focus = .list
    public var detail: Detail = .empty
    public var currentUser: UserSession?
    public var overlay: Overlay?
    public var toast: Toast?
    public var isLoadingFeed = false
    public var isLoadingMore = false
    public var isLoadingThread = false
    public var hasMore = false
    public var readIDs: Set<ItemID> = []
    public var shouldQuit = false
    public var pendingEditor: EditorRequest?
    public var spinnerIndex = 0
    public var listViewportHeight = 10
    public var detailViewportHeight = 10
    public var screenWidth = 100
    public var screenHeight = 30
    public var hitRegions: [HitRegion] = []
    public var listPaneRect: Rect?
    public var detailPaneRect: Rect?
    public var onChange: (() -> Void)?

    private var feedCache: [Source: FeedCache] = [:]
    var threadCache: [ItemID: TUIThread] = [:]
    private var feedTask: Task<Void, Never>?
    private var threadTask: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?
    private var sourceGeneration = 0
    private var threadGeneration = 0
    var pendingSourceAfterLogin: Source?
    var pendingSubmitTitle: String?
    private var didBootstrap = false

    public static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    public init(client: HackerNewsClient, initialSource: Source = .feed(.frontPage)) {
        self.client = client
        self.sidebarSections = SidebarSection.standard(pastDay: TUIDate.yesterday())
        self.sidebarSources = sidebarSections.flatMap(\.items)
        self.source = initialSource
        self.selectedSourceIndex = sidebarSources.firstIndex(of: initialSource) ?? 0
    }

    public func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        Task {
            currentUser = await client.currentSession()
            notifyChange()
            loadSource(reset: true)

            if currentUser != nil {
                currentUser = try? await client.validateSession()
                notifyChange()
            }
        }
    }

    public var showSidebar: Bool {
        screenWidth >= 78
    }

    public var isNarrow: Bool {
        screenWidth < 70
    }

    public var visiblePaneCount: Int {
        var count = 1
        if showSidebar { count += 1 }
        if !isNarrow || focus == .detail { count += 1 }
        return count
    }

    public var currentSourceLabel: String {
        source.label
    }

    public var spinner: String {
        Self.spinnerFrames[spinnerIndex % Self.spinnerFrames.count]
    }

    // MARK: - Source loading

    public func selectSource(_ next: Source) {
        if next == source {
            focus = .list
            if entries.isEmpty, !isLoadingFeed {
                loadSource(reset: true)
            }
            return
        }

        feedTask?.cancel()
        feedTask = nil
        isLoadingFeed = false
        isLoadingMore = false
        sourceGeneration += 1

        saveCurrentCache()
        source = next
        if let index = sidebarSources.firstIndex(of: next) {
            selectedSourceIndex = index
        }

        if next.requiresAuthentication, currentUser == nil {
            entries = []
            hasMore = false
            selectedEntryIndex = 0
            listScroll = 0
            detail = .empty
            focus = .list
            openLogin(pendingSource: next)
            return
        }

        if let cache = feedCache[next] {
            entries = cache.entries
            hasMore = cache.hasMore
            selectedEntryIndex = cache.selectedIndex
            listScroll = cache.scroll
            focus = .list
            setPreview()
            ensureSelectionVisible()
            maybeLoadMore()
        } else {
            entries = []
            hasMore = false
            selectedEntryIndex = 0
            listScroll = 0
            detail = .empty
            focus = .list
            loadSource(reset: true)
        }
    }

    public func loadSource(reset: Bool) {
        notifyChange()
        if reset {
            sourceGeneration += 1
            isLoadingFeed = true
            isLoadingMore = false
            hasMore = false
        } else {
            guard !isLoadingFeed, !isLoadingMore else { return }
            isLoadingMore = true
        }

        let source = self.source
        let generation = sourceGeneration
        let offset = reset ? 0 : entries.count
        let page: PageRequest
        do {
            page = try PageRequest(offset: offset, limit: 30)
        } catch {
            isLoadingFeed = false
            isLoadingMore = false
            showToast(error.localizedDescription, style: .error)
            return
        }

        feedTask?.cancel()
        feedTask = Task {
            do {
                switch source {
                case .feed(let feed):
                    let sitePage = try await client.site.feedEntries(for: feed, page: page)
                    guard generation == self.sourceGeneration, source == self.source else { return }
                    apply(
                        entries: sitePage.entries.map { TUIEntry(siteEntry: $0) },
                        reset: reset,
                        hasMore: sitePage.hasMore
                    )

                case .upvoted, .hidden:
                    guard let session = currentUser else {
                        throw HackerNewsError.unauthenticated
                    }
                    let kind: UserActivityKind = source == .upvoted ? .upvoted : .hidden
                    let sitePage = try await client.site.activityEntries(
                        for: session.userID,
                        activity: kind,
                        page: page
                    )
                    guard generation == self.sourceGeneration, source == self.source else { return }
                    apply(
                        entries: sitePage.entries.map { TUIEntry(siteEntry: $0) },
                        reset: reset,
                        hasMore: sitePage.hasMore
                    )

                case .search(let query):
                    let results = try await SearchHackerNews(provider: client)(
                        SearchQuery(
                            terms: query,
                            kinds: [.story, .comment],
                            page: page
                        )
                    )
                    guard generation == self.sourceGeneration, source == self.source else { return }
                    let hits = results.hits.map { TUIEntry(hit: $0) }
                    apply(entries: hits, reset: reset, hasMore: results.hasMore)
                }
            } catch {
                if Task.isCancelled { return }
                guard generation == self.sourceGeneration, source == self.source else { return }
                isLoadingFeed = false
                isLoadingMore = false
                if let hnError = error as? HackerNewsError, case .unauthenticated = hnError {
                    currentUser = nil
                    openLogin(pendingSource: source.requiresAuthentication ? source : nil)
                }
                showToast(error.localizedDescription, style: .error)
            }
        }
    }

    public func cancelBackgroundWork() {
        feedTask?.cancel()
        feedTask = nil
        threadTask?.cancel()
        threadTask = nil
        replyTask?.cancel()
        replyTask = nil
    }

    private func apply(entries newEntries: [TUIEntry], reset: Bool, hasMore: Bool) {
        if reset {
            entries = newEntries
            selectedEntryIndex = 0
            listScroll = 0
        } else {
            let existing = Set(entries.map(\.id))
            entries.append(contentsOf: newEntries.filter { !existing.contains($0.id) })
        }

        self.hasMore = hasMore
        isLoadingFeed = false
        isLoadingMore = false
        setPreview()
        ensureSelectionVisible()
        maybeLoadMore()
        saveCurrentCache()
        notifyChange()
    }

    public func refresh() {
        feedCache[source] = nil
        if case .thread = detail {
            reloadThread()
        }
        loadSource(reset: true)
        showToast("Refreshed \(source.label)", style: .info)
    }

    public func maybeLoadMore() {
        guard hasMore, !isLoadingFeed, !isLoadingMore, !entries.isEmpty else { return }
        guard selectedEntryIndex >= entries.count - 4 else { return }
        loadSource(reset: false)
    }

    public func saveCurrentCache() {
        guard !entries.isEmpty else { return }
        feedCache[source] = FeedCache(
            entries: entries,
            hasMore: hasMore,
            selectedIndex: selectedEntryIndex,
            scroll: listScroll
        )
    }

    // MARK: - Threads

    public func openSelected() {
        switch focus {
        case .sidebar:
            guard sidebarSources.indices.contains(selectedSourceIndex) else { return }
            selectSource(sidebarSources[selectedSourceIndex])
            focus = .list

        case .list:
            guard entries.indices.contains(selectedEntryIndex) else { return }
            openEntry(entries[selectedEntryIndex])

        case .detail:
            switch detail {
            case .preview(let entry):
                openEntry(entry)
            case .thread:
                toggleCollapse()
            case .empty, .loading, .error:
                break
            }
        }
    }

    public func openEntry(_ entry: TUIEntry) {
        if let cached = threadCache[entry.id] {
            detail = .thread(cached)
            focus = .detail
            markRead(entry.id)
            ensureSelectionVisible()
            return
        }

        threadGeneration += 1
        let generation = threadGeneration
        detail = .preview(entry)
        isLoadingThread = true
        focus = .detail
        markRead(entry.id)

        threadTask?.cancel()
        threadTask = Task {
            do {
                let thread: HackerNewsCore.Thread
                do {
                    thread = try await client.algolia.itemTree(id: entry.id)
                } catch {
                    thread = try await LoadThread(items: client)(
                        rootID: entry.id,
                        policy: ThreadLoadPolicy(
                            maxDepth: 1,
                            maxNodes: 31,
                            maxConcurrentRequests: 30
                        )
                    )
                }
                guard generation == self.threadGeneration else { return }
                let tuiThread = self.makeThread(from: thread, fullyLoaded: thread.isComplete)
                threadCache[entry.id] = tuiThread
                isLoadingThread = false
                detail = .thread(tuiThread)
                ensureSelectionVisible()
                notifyChange()
            } catch {
                if Task.isCancelled { return }
                guard generation == self.threadGeneration else { return }
                isLoadingThread = false
                detail = .error(entry.id, error.localizedDescription)
                showToast(error.localizedDescription, style: .error)
                notifyChange()
            }
        }
    }

    private func makeThread(from thread: HackerNewsCore.Thread, fullyLoaded: Bool) -> TUIThread {
        if fullyLoaded {
            func makeNode(_ node: ThreadNode) -> TUICommentNode {
                let replies = node.replies.map(makeNode)
                return TUICommentNode(
                    item: node.item,
                    replies: node.replies.isEmpty ? [] : replies
                )
            }
            return TUIThread(
                root: thread.root,
                topLevel: thread.replies.map(makeNode)
            )
        }

        let topLevel = thread.replies.map { node in
            TUICommentNode(
                item: node.item,
                replies: node.item.childIDs.isEmpty ? [] : nil
            )
        }
        return TUIThread(root: thread.root, topLevel: topLevel)
    }

    public func reloadThread() {
        let rootID: ItemID?
        if case .thread(let threadView) = detail {
            rootID = threadView.root.id
        } else if case .loading(let id) = detail {
            rootID = id
        } else {
            rootID = nil
        }
        guard let rootID else { return }

        threadCache[rootID] = nil
        threadGeneration += 1
        let generation = threadGeneration
        let previousDetail = detail
        isLoadingThread = true
        if case .thread = previousDetail {
            detail = previousDetail
        } else {
            detail = .loading(rootID)
        }

        threadTask?.cancel()
        threadTask = Task {
            do {
                let thread: HackerNewsCore.Thread
                do {
                    thread = try await client.algolia.itemTree(id: rootID)
                } catch {
                    thread = try await LoadThread(items: client)(
                        rootID: rootID,
                        policy: ThreadLoadPolicy(
                            maxDepth: 1,
                            maxNodes: 31,
                            maxConcurrentRequests: 30
                        )
                    )
                }
                guard generation == self.threadGeneration else { return }
                let tuiThread = self.makeThread(from: thread, fullyLoaded: thread.isComplete)
                threadCache[rootID] = tuiThread
                isLoadingThread = false
                detail = .thread(tuiThread)
                ensureSelectionVisible()
                notifyChange()
            } catch {
                if Task.isCancelled { return }
                guard generation == self.threadGeneration else { return }
                isLoadingThread = false
                detail = .error(rootID, error.localizedDescription)
                showToast(error.localizedDescription, style: .error)
                notifyChange()
            }
        }
    }

    // MARK: - Navigation

    public func moveSelection(by delta: Int) {
        switch focus {
        case .sidebar:
            let count = sidebarSources.count
            guard count > 0 else { return }
            selectedSourceIndex = min(max(0, selectedSourceIndex + delta), count - 1)

        case .list:
            let count = entries.count
            guard count > 0 else { return }
            selectedEntryIndex = min(max(0, selectedEntryIndex + delta), count - 1)
            setPreview()
            ensureSelectionVisible()
            maybeLoadMore()

        case .detail:
            guard case .thread(let threadView) = detail else { return }
            guard !threadView.visible.isEmpty else { return }
            threadView.selectedIndex = min(
                max(0, threadView.selectedIndex + delta),
                threadView.visible.count - 1
            )
            detail = .thread(threadView)
            ensureSelectionVisible()
        }
    }

    public func moveToTop() {
        switch focus {
        case .sidebar:
            selectedSourceIndex = 0
        case .list:
            selectedEntryIndex = 0
            listScroll = 0
            setPreview()
            ensureSelectionVisible()
        case .detail:
            guard case .thread(let threadView) = detail else { return }
            threadView.selectedIndex = 0
            detail = .thread(threadView)
            ensureSelectionVisible()
        }
    }

    public func moveToBottom() {
        switch focus {
        case .sidebar:
            selectedSourceIndex = max(0, sidebarSources.count - 1)
        case .list:
            selectedEntryIndex = max(0, entries.count - 1)
            setPreview()
            ensureSelectionVisible()
            maybeLoadMore()
        case .detail:
            guard case .thread(let threadView) = detail else { return }
            threadView.selectedIndex = max(0, threadView.visible.count - 1)
            detail = .thread(threadView)
            ensureSelectionVisible()
        }
    }

    public func page(delta: Int) {
        let amount = focus == .detail ? max(1, detailViewportHeight / 3) : max(1, listViewportHeight / 2)
        moveSelection(by: delta * amount)
    }

    public func cycleFocus() {
        switch focus {
        case .sidebar:
            focus = .list
        case .list:
            if case .thread = detail {
                focus = .detail
            } else if showSidebar {
                focus = .sidebar
            }
        case .detail:
            if showSidebar {
                focus = .sidebar
            } else {
                focus = .list
            }
        }
    }

    public func goBack() {
        if overlay != nil {
            closeOverlay()
            return
        }

        if focus == .detail {
            focus = .list
            setPreview()
            return
        }

        if !showSidebar && focus == .list {
            return
        }
    }

    public var selectedCommentIndex: Int? {
        guard case .thread(let threadView) = detail else { return nil }
        return threadView.selectedIndex
    }

    public func selectComment(at index: Int) {
        guard case .thread(let threadView) = detail else { return }
        guard threadView.visible.indices.contains(index) else { return }
        threadView.selectedIndex = index
        detail = .thread(threadView)
        focus = .detail
        ensureSelectionVisible()
    }

    public func toggleCollapse() {
        guard case .thread(let threadView) = detail,
              let node = threadView.selectedNode
        else {
            return
        }

        if node.replies == nil, node.hasChildren {
            guard !node.isLoading else { return }
            node.isLoading = true
            notifyChange()

            replyTask?.cancel()
            replyTask = Task {
                do {
                    let data = try await LoadThread(items: client)(
                        rootID: node.id,
                        policy: ThreadLoadPolicy(
                            maxDepth: 1,
                            maxNodes: 31,
                            maxConcurrentRequests: 30
                        )
                    )
                    if Task.isCancelled { return }
                    guard case .thread(let current) = detail, current === threadView else { return }
                    node.replies = data.replies.map { child in
                        TUICommentNode(
                            item: child.item,
                            replies: child.item.childIDs.isEmpty ? [] : nil
                        )
                    }
                    node.isLoading = false
                    node.isExpanded = true
                    threadView.rebuild()
                    detail = .thread(threadView)
                    ensureSelectionVisible()
                    notifyChange()
                } catch {
                    if Task.isCancelled { return }
                    node.isLoading = false
                    showToast(error.localizedDescription, style: .error)
                    notifyChange()
                }
            }
            return
        }

        guard node.hasChildren else { return }
        node.isExpanded.toggle()
        threadView.rebuild()
        detail = .thread(threadView)
        ensureSelectionVisible()
    }

    public func setPreview() {
        guard entries.indices.contains(selectedEntryIndex) else {
            detail = .empty
            return
        }
        detail = .preview(entries[selectedEntryIndex])
    }

    public func ensureSelectionVisible() {
        if focus == .list || focusedOnList {
            let visibleEntries = max(1, listViewportHeight / 2)
            if selectedEntryIndex < listScroll {
                listScroll = selectedEntryIndex
            } else if selectedEntryIndex >= listScroll + visibleEntries {
                listScroll = selectedEntryIndex - visibleEntries + 1
            }
            listScroll = max(0, listScroll)
        }

        if case .thread(let threadView) = detail {
            let visibleComments = max(1, detailViewportHeight / 3)
            if threadView.selectedIndex < threadView.startIndex {
                threadView.startIndex = threadView.selectedIndex
            } else if threadView.selectedIndex >= threadView.startIndex + visibleComments {
                threadView.startIndex = threadView.selectedIndex - visibleComments + 1
            }
            threadView.startIndex = max(0, threadView.startIndex)
            detail = .thread(threadView)
        }
    }

    public var focusedOnList: Bool {
        focus == .list
    }

    // MARK: - Mouse / scrolling

    public func scrollList(by delta: Int) {
        guard !entries.isEmpty else { return }
        selectedEntryIndex = min(max(0, selectedEntryIndex + delta), entries.count - 1)
        setPreview()
        ensureSelectionVisible()
        maybeLoadMore()
    }

    public func scrollDetail(by delta: Int) {
        guard case .thread(let threadView) = detail else { return }
        guard !threadView.visible.isEmpty else { return }
        threadView.selectedIndex = min(
            max(0, threadView.selectedIndex + delta),
            threadView.visible.count - 1
        )
        detail = .thread(threadView)
        ensureSelectionVisible()
    }

    // MARK: - Utility

    public func markRead(_ id: ItemID) {
        readIDs.insert(id)
    }

    public func showToast(_ message: String, style: ToastStyle = .info) {
        toast = Toast(text: message, style: style, expiresAt: Date().addingTimeInterval(4))
        notifyChange()
    }

    public func notifyChange() {
        onChange?()
    }

    public func tick() {
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerFrames.count
        if let toast, toast.expiresAt <= Date() {
            self.toast = nil
            notifyChange()
        }
    }

    public var isBusy: Bool {
        isLoadingFeed || isLoadingMore || isLoadingThread
    }

    public var currentUserLabel: String {
        if let currentUser {
            return currentUser.userID.rawValue
        }
        return "not logged in"
    }

    public var selectedEntry: TUIEntry? {
        guard entries.indices.contains(selectedEntryIndex) else { return nil }
        return entries[selectedEntryIndex]
    }

    public func selectSource(at index: Int) {
        guard sidebarSources.indices.contains(index) else { return }
        selectedSourceIndex = index
        selectSource(sidebarSources[index])
    }

    public func cycleSource(by delta: Int) {
        guard !sidebarSources.isEmpty else { return }
        let current = sidebarSources.firstIndex(of: source) ?? selectedSourceIndex
        let next = (current + delta + sidebarSources.count) % sidebarSources.count
        selectSource(at: next)
    }

    public var targetEntry: TUIEntry? {
        if focus == .sidebar {
            return nil
        }
        if focus == .detail, case .thread(let threadView) = detail, let comment = threadView.selectedNode {
            return TUIEntry(item: comment.item)
        }
        if case .preview(let entry) = detail {
            return entry
        }
        return selectedEntry
    }
}
