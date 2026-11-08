import Foundation
import HackerNewsCore
import HackerNewsAdapters

public enum TUIEvent: Sendable {
    case key(KeyEvent)
    case resize(Int, Int)
    case render
    case tick
    case eof
}

final class TUIEventBus: @unchecked Sendable {
    let stream: AsyncStream<TUIEvent>
    private let continuation: AsyncStream<TUIEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: TUIEvent.self)
    }

    func send(_ event: TUIEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}

@MainActor
public final class Browser {
    private let terminal = Terminal()
    private let state: BrowserState
    private let bus: TUIEventBus
    private let screen = Screen(width: 80, height: 24)
    private var input: TerminalInput?
    private var ticker: Task<Void, Never>?

    public init(client: HackerNewsClient, initialSource: Source = .feed(.frontPage)) {
        let bus = TUIEventBus()
        let state = BrowserState(client: client, initialSource: initialSource)
        state.onChange = { bus.send(.render) }
        self.bus = bus
        self.state = state
    }

    public func run() async throws {
        try terminal.start()
        defer {
            ticker?.cancel()
            input?.stop()
            terminal.stop()
        }

        screen.resize(width: terminal.width, height: terminal.height)
        let input = TerminalInput(
            terminal: terminal,
            onKey: { [bus] event in bus.send(.key(event)) },
            onResize: { [bus] width, height in bus.send(.resize(width, height)) },
            onEOF: { [bus] in bus.send(.eof) }
        )
        self.input = input
        input.start()

        ticker = Task { [bus] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { break }
                bus.send(.tick)
            }
        }

        state.bootstrap()
        render()

        for await event in bus.stream {
            var needsRender = false

            switch event {
            case .key(let key):
                handle(key: key)
                needsRender = true

            case .resize:
                terminal.refreshSize()
                screen.resize(width: terminal.width, height: terminal.height)
                terminal.clearScreen()
                needsRender = true

            case .render:
                needsRender = true

            case .tick:
                state.tick()
                if state.isBusy || state.toast != nil {
                    needsRender = true
                }

            case .eof:
                state.shouldQuit = true
            }

            if state.shouldQuit {
                break
            }

            if let request = state.takeEditorRequest() {
                await runEditor(request)
                needsRender = true
            }

            if needsRender {
                render()
            }
        }

        state.saveActiveDraft()
        state.cancelBackgroundWork()
        bus.finish()
    }

    private func render() {
        if screen.width != terminal.width || screen.height != terminal.height {
            screen.resize(width: terminal.width, height: terminal.height)
        }
        BrowserView.render(state, into: screen)
        terminal.write(screen.render())
    }

    private func handle(key: KeyEvent) {
        if key == .ctrl("c") {
            state.saveActiveDraft()
            state.shouldQuit = true
            return
        }

        if state.overlay != nil {
            handleOverlayKey(key)
            return
        }

        switch key {
        case .character("q"):
            state.shouldQuit = true

        case .character("?"):
            state.overlay = .help

        case .character(":"):
            state.openCommands()

        case .ctrl("p"):
            state.openCommands()

        case .character("/"):
            state.openSearch()

        case .character("L"):
            state.openLogin()

        case .character("r"), .ctrl("r"):
            state.refresh()

        case .character("j"), .down:
            state.moveSelection(by: 1)

        case .character("k"), .up:
            state.moveSelection(by: -1)

        case .character("g"), .home:
            state.moveToTop()

        case .character("G"), .end:
            state.moveToBottom()

        case .ctrl("d"), .pageDown:
            state.page(delta: 1)

        case .ctrl("u"), .pageUp:
            state.page(delta: -1)

        case .tab:
            state.cycleFocus()

        case .backTab:
            state.cycleFocus()

        case .enter, .character("l"), .right:
            state.openSelected()

        case .escape, .character("h"), .left:
            state.goBack()

        case .character(" "):
            if state.focus == .detail {
                state.toggleCollapse()
            } else {
                state.openSelected()
            }

        case .character("v"):
            state.requestVote(.up)

        case .character("V"):
            state.requestVote(.down)

        case .character("u"):
            state.requestVote(.unvote)

        case .character("f"):
            state.requestFavorite(undo: false)

        case .character("F"):
            state.requestFavorite(undo: true)

        case .character("H"):
            state.requestHide(undo: false)

        case .character("U"):
            state.requestHide(undo: true)

        case .character("!"):
            state.requestFlag()

        case .character("c"):
            state.requestComment()

        case .character("e"):
            state.requestEdit()

        case .character("d"):
            state.requestDeleteSelected()

        case .character("s"):
            state.requestSubmit()

        case .character("o"):
            state.requestOpenInBrowser()

        case .character("y"):
            state.requestCopyURL()

        case .character("["):
            state.cycleSource(by: -1)

        case .character("]"):
            state.cycleSource(by: 1)

        case .character(let character) where character.isNumber:
            if let value = Int(String(character)) {
                state.selectSource(at: value - 1)
            }

        case .mouse(let mouse):
            handle(mouse: mouse)

        default:
            break
        }
    }

    private func handleOverlayKey(_ key: KeyEvent) {
        switch state.overlay {
        case .help:
            state.closeOverlay()

        case .commands:
            switch key {
            case .escape:
                state.closeOverlay()
            case .enter:
                state.submitActiveInput()
            case .up, .ctrl("p"):
                state.moveCommandSelection(by: -1)
            case .down, .ctrl("n"):
                state.moveCommandSelection(by: 1)
            case .backspace:
                state.backspaceActiveInput()
            case .character(let character):
                if character == " " || !character.isNewline {
                    state.appendActiveInput(String(character))
                }
            case .paste(let text):
                state.appendActiveInput(text)
            default:
                break
            }

        case .search:
            switch key {
            case .escape:
                state.closeOverlay()
            case .enter:
                state.submitActiveInput()
            case .backspace:
                state.backspaceActiveInput()
            case .character(let character):
                state.appendActiveInput(String(character))
            case .paste(let text):
                state.appendActiveInput(text)
            default:
                break
            }

        case .login:
            switch key {
            case .escape:
                state.closeOverlay()
            case .tab, .backTab:
                state.toggleLoginField()
            case .enter:
                state.submitActiveInput()
            case .backspace:
                state.backspaceActiveInput()
            case .character(let character):
                state.appendActiveInput(String(character))
            case .paste(let text):
                state.appendActiveInput(text)
            default:
                break
            }

        case .prompt:
            switch key {
            case .escape:
                state.closeOverlay()
            case .enter:
                state.submitActiveInput()
            case .backspace:
                state.backspaceActiveInput()
            case .character(let character):
                state.appendActiveInput(String(character))
            case .paste(let text):
                state.appendActiveInput(text)
            default:
                break
            }

        case .confirm:
            switch key {
            case .escape, .character("n"), .character("N"):
                state.confirmNo()
            case .character("y"), .character("Y"):
                state.confirmYes()
            default:
                break
            }

        case .compose:
            switch key {
            case .escape:
                state.cancelCompose()
            case .ctrl("s"):
                state.submitCompose()
            case .ctrl("e"):
                state.openExternalEditorForCompose()
            case .enter:
                state.composeInsert("\n")
            case .tab:
                state.composeInsert("  ")
            case .backspace:
                state.composeBackspace()
            case .delete:
                state.composeDeleteForward()
            case .left:
                state.composeMoveLeft()
            case .right:
                state.composeMoveRight()
            case .up:
                state.composeMoveUp()
            case .down:
                state.composeMoveDown()
            case .home, .ctrl("a"):
                state.composeMoveHome()
            case .end:
                state.composeMoveEnd()
            case .pageUp:
                state.composePage(up: true)
            case .pageDown:
                state.composePage(up: false)
            case .character(let character):
                state.composeInsert(String(character))
            case .paste(let text):
                state.composeInsert(text)
            default:
                break
            }

        case .none:
            break
        }
    }

    private func handle(mouse: MouseEvent) {
        guard state.overlay == nil else { return }

        if mouse.action == .scrollUp || mouse.action == .scrollDown {
            let delta = mouse.action == .scrollUp ? -1 : 1
            if let detail = state.detailPaneRect, detail.contains(x: mouse.x, y: mouse.y) {
                state.scrollDetail(by: delta)
            } else if let list = state.listPaneRect, list.contains(x: mouse.x, y: mouse.y) {
                state.scrollList(by: delta)
            }
            return
        }

        guard mouse.action == .press, mouse.button == .left else { return }

        for region in state.hitRegions.reversed() {
            guard region.rect.contains(x: mouse.x, y: mouse.y) else { continue }
            switch region.action {
            case .source(let index):
                state.selectedSourceIndex = index
                state.selectSource(at: index)
                state.focus = .list

            case .entry(let index):
                if state.focus == .list, state.selectedEntryIndex == index {
                    state.openSelected()
                } else {
                    state.selectedEntryIndex = index
                    state.focus = .list
                    state.setPreview()
                    state.ensureSelectionVisible()
                    state.maybeLoadMore()
                }

            case .comment(let index):
                if state.focus == .detail, state.selectedCommentIndex == index {
                    state.toggleCollapse()
                } else {
                    state.selectComment(at: index)
                }
            }
            return
        }
    }

    private func runEditor(_ request: BrowserState.EditorRequest) async {
        let initial: String
        switch request {
        case .compose(let text):
            initial = text
        }

        input?.stop()
        terminal.suspend()

        var result: Result<String, Error>
        do {
            result = .success(try TUIEditor.edit(initial: initial))
        } catch {
            result = .failure(error)
        }

        do {
            try terminal.resume()
        } catch {
            state.shouldQuit = true
            return
        }

        screen.resize(width: terminal.width, height: terminal.height)
        terminal.clearScreen()
        input?.start()

        switch result {
        case .success(let text):
            state.handleExternalEditorResult(text: text)
        case .failure(let error):
            state.showToast(error.localizedDescription, style: .warning)
        }

        render()
    }

}

public enum TUI {
    @MainActor
    public static func run(
        client: HackerNewsClient = HackerNewsClient(),
        initialSource: Source = .feed(.frontPage)
    ) async throws {
        let browser = Browser(client: client, initialSource: initialSource)
        try await browser.run()
    }
}
