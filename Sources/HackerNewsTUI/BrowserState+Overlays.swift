import Foundation
import HackerNewsCore
import HackerNewsAdapters

extension BrowserState {
    // MARK: - Commands

    public var allCommands: [TUICommand] {
        var commands: [TUICommand] = sidebarSources.map { source in
            TUICommand(
                id: "source-\(source.label)",
                title: "Go to \(source.label)",
                subtitle: source.requiresAuthentication ? "requires login" : nil,
                keywords: "\(source.label) feed",
                action: .source(source)
            )
        }

        commands.append(contentsOf: [
            TUICommand(
                id: "search",
                title: "Search Hacker News",
                subtitle: "/",
                keywords: "find query search",
                action: .search
            ),
            TUICommand(
                id: "submit",
                title: "Submit a story",
                subtitle: "s",
                keywords: "post link text submit",
                action: .submit
            ),
            TUICommand(
                id: "from-site",
                title: "Submissions from a site…",
                subtitle: "from",
                keywords: "domain site from",
                action: .fromSite
            ),
            TUICommand(
                id: "past",
                title: "Past front page…",
                subtitle: "archive",
                keywords: "past archive date",
                action: .past
            ),
            TUICommand(
                id: "refresh",
                title: "Refresh",
                subtitle: "r",
                keywords: "reload refresh",
                action: .refresh
            ),
            currentUser == nil
                ? TUICommand(
                    id: "login",
                    title: "Log in…",
                    subtitle: "L",
                    keywords: "auth sign in login",
                    action: .login
                )
                : TUICommand(
                    id: "logout",
                    title: "Log out",
                    subtitle: "auth",
                    keywords: "auth sign out logout",
                    action: .logout
                ),
            TUICommand(
                id: "help",
                title: "Keyboard help",
                subtitle: "?",
                keywords: "keys help",
                action: .help
            ),
            TUICommand(
                id: "quit",
                title: "Quit",
                subtitle: "q",
                keywords: "exit close quit",
                action: .quit
            ),
        ])

        return commands
    }

    public var filteredCommands: [TUICommand] {
        guard case .commands(let palette) = overlay else { return [] }
        let query = palette.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allCommands }
        return allCommands.filter {
            ($0.title + " " + $0.keywords).lowercased().contains(query)
        }
    }

    public func openCommands() {
        overlay = .commands(CommandPalette(query: "", selectedIndex: 0))
    }

    public func moveCommandSelection(by delta: Int) {
        guard case .commands(var palette) = overlay else { return }
        let count = filteredCommands.count
        guard count > 0 else { return }
        palette.selectedIndex = min(max(0, palette.selectedIndex + delta), count - 1)
        overlay = .commands(palette)
    }

    public func executeSelectedCommand() {
        let commands = filteredCommands
        guard case .commands(let palette) = overlay,
              commands.indices.contains(palette.selectedIndex)
        else {
            closeOverlay()
            return
        }

        let command = commands[palette.selectedIndex]
        overlay = nil

        switch command.action {
        case .source(let source):
            selectSource(source)
            focus = .list
        case .search:
            openSearch()
        case .login:
            openLogin(pendingSource: nil)
        case .logout:
            overlay = .confirm(
                Confirm(message: "Log out of Hacker News?", kind: .logout)
            )
        case .refresh:
            refresh()
        case .submit:
            beginSubmit()
        case .fromSite:
            openPrompt(.fromSite)
        case .past:
            openPrompt(.pastDate)
        case .help:
            overlay = .help
        case .quit:
            shouldQuit = true
        }
    }

    // MARK: - Search

    public func openSearch() {
        let existing: String
        if case .search(let query) = source {
            existing = query
        } else {
            existing = ""
        }
        overlay = .search(SearchPalette(query: existing))
    }

    public func performSearch(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            closeOverlay()
            return
        }
        overlay = nil
        selectSource(.search(query))
        focus = .list
    }

    // MARK: - Login

    public func openLogin(pendingSource: Source? = nil) {
        if let currentUser {
            showToast("Already logged in as \(currentUser.userID.rawValue)", style: .info)
            return
        }
        pendingSourceAfterLogin = pendingSource
        overlay = .login(
            LoginForm(
                username: "",
                password: "",
                focusedField: 0,
                error: nil,
                isSubmitting: false
            )
        )
    }

    public func submitLogin() {
        guard case .login(var form) = overlay, !form.isSubmitting else { return }

        let username = form.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            form.error = "Enter your username"
            overlay = .login(form)
            return
        }
        guard !form.password.isEmpty else {
            form.error = "Enter your password"
            overlay = .login(form)
            return
        }

        form.isSubmitting = true
        form.error = nil
        overlay = .login(form)

        Task {
            do {
                let credentials = try Credentials(username: username, password: form.password)
                let session = try await client.logIn(credentials)
                currentUser = session
                overlay = nil
                showToast("Logged in as \(session.userID.rawValue)", style: .success)

                if let pending = pendingSourceAfterLogin {
                    pendingSourceAfterLogin = nil
                    selectSource(pending)
                    focus = .list
                } else if source.requiresAuthentication {
                    loadSource(reset: true)
                }
            } catch {
                form.isSubmitting = false
                form.error = error.localizedDescription
                overlay = .login(form)
                notifyChange()
            }
        }
    }

    public func logout() {
        Task {
            do {
                try await client.logOut()
                currentUser = nil
                overlay = nil
                showToast("Logged out", style: .info)
                if source.requiresAuthentication {
                    selectSource(.feed(.frontPage))
                }
            } catch {
                showToast(error.localizedDescription, style: .error)
            }
        }
    }

    public func toggleLoginField() {
        guard case .login(var form) = overlay else { return }
        form.focusedField = form.focusedField == 0 ? 1 : 0
        overlay = .login(form)
    }

    // MARK: - Prompts

    public func openPrompt(_ kind: PromptKind) {
        let title: String
        let placeholder: String
        switch kind {
        case .fromSite:
            title = "Submissions from site"
            placeholder = "example.com"
        case .pastDate:
            title = "Past front page"
            placeholder = "YYYY-MM-DD"
        case .flagReason:
            title = "Flag reason"
            placeholder = "optional"
        case .submitTitle:
            title = "Story title"
            placeholder = "title"
        case .submitURL:
            title = "Story URL"
            placeholder = "https://… (empty for text post)"
        }

        overlay = .prompt(
            Prompt(title: title, placeholder: placeholder, text: "", kind: kind)
        )
    }

    public func beginSubmit() {
        pendingSubmitTitle = nil
        openPrompt(.submitTitle)
    }

    public func submitPrompt() {
        guard case .prompt(let prompt) = overlay else { return }
        let text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch prompt.kind {
        case .fromSite:
            guard !text.isEmpty else {
                showToast("Enter a domain", style: .warning)
                return
            }
            var site = text
            if let url = URL(string: text), let host = url.host {
                site = host
            }
            overlay = nil
            selectSource(.feed(.fromSite(site)))

        case .pastDate:
            guard let day = CalendarDay(iso8601: text) else {
                showToast("Use YYYY-MM-DD", style: .warning)
                return
            }
            overlay = nil
            selectSource(.feed(.pastFrontPage(day)))

        case .flagReason:
            overlay = nil
            performFlag(reason: text)

        case .submitTitle:
            guard !text.isEmpty else {
                showToast("Enter a title", style: .warning)
                return
            }
            pendingSubmitTitle = text
            overlay = .prompt(
                Prompt(
                    title: "Story URL",
                    placeholder: "https://… (empty for text post)",
                    text: "",
                    kind: .submitURL
                )
            )

        case .submitURL:
            let title = pendingSubmitTitle ?? ""
            if text.isEmpty {
                overlay = nil
                requestSubmitText(title: title)
            } else {
                guard let url = URL(string: text), url.scheme != nil else {
                    showToast("Enter a valid absolute URL", style: .warning)
                    return
                }
                overlay = nil
                performSubmit(title: title, url: url)
            }
        }
    }

    // MARK: - Confirmation

    public func requestDeleteSelected() {
        guard let target = targetEntry else { return }
        overlay = .confirm(
            Confirm(message: "Delete item \(target.id)?", kind: .delete(target.id))
        )
    }

    public func confirmYes() {
        guard case .confirm(let confirm) = overlay else { return }
        overlay = nil

        switch confirm.kind {
        case .delete(let id):
            performDelete(id: id)
        case .logout:
            logout()
        case .quit:
            shouldQuit = true
        }
    }

    public func confirmNo() {
        closeOverlay()
    }

    // MARK: - Actions

    public func requestVote(_ direction: VoteDirection) {
        guard let target = targetEntry else { return }
        performVote(target: target, direction: direction)
    }

    public func performVote(target: TUIEntry, direction: VoteDirection) {
        Task {
            do {
                try await client.vote(on: target.id, direction: direction)
                let verb: String = switch direction {
                case .up: "Upvoted"
                case .down: "Downvoted"
                case .unvote: "Removed vote on"
                }
                showToast("\(verb) \(target.id)", style: .success)
            } catch {
                handleActionError(error)
            }
        }
    }

    public func requestFavorite(undo: Bool) {
        guard let target = targetEntry else { return }
        performFavorite(target: target, undo: undo)
    }

    public func performFavorite(target: TUIEntry, undo: Bool) {
        Task {
            do {
                try await client.setFavorite(!undo, on: target.id)
                showToast(
                    undo ? "Removed \(target.id) from favorites" : "Favorited \(target.id)",
                    style: .success
                )
            } catch {
                handleActionError(error)
            }
        }
    }

    public func requestHide(undo: Bool) {
        guard let target = targetEntry else { return }
        performHide(target: target, undo: undo)
    }

    public func performHide(target: TUIEntry, undo: Bool) {
        Task {
            do {
                try await client.setHidden(!undo, on: target.id)
                showToast(
                    undo ? "Unhid \(target.id)" : "Hid \(target.id)",
                    style: .success
                )
            } catch {
                handleActionError(error)
            }
        }
    }

    public func requestFlag() {
        guard targetEntry != nil else { return }
        openPrompt(.flagReason)
    }

    public func performFlag(reason: String) {
        guard let target = targetEntry else { return }
        Task {
            do {
                try await client.flag(itemID: target.id, reason: reason)
                showToast("Flagged \(target.id)", style: .success)
            } catch {
                handleActionError(error)
            }
        }
    }

    public func requestSubmit() {
        beginSubmit()
    }

    public func requestOpenInBrowser() {
        guard let target = targetEntry else { return }
        let url = target.url ?? URL(string: "https://news.ycombinator.com/item?id=\(target.id.rawValue)")!
        openURL(url)
    }

    public func requestCopyURL() {
        guard let target = targetEntry else { return }
        let string = target.url?.absoluteString
            ?? "https://news.ycombinator.com/item?id=\(target.id.rawValue)"
        copyToClipboard(string)
        showToast("Copied URL", style: .success)
    }

    public func takeEditorRequest() -> EditorRequest? {
        defer { pendingEditor = nil }
        return pendingEditor
    }

    public func performSubmit(title: String, url: URL? = nil, text: String? = nil) {
        do {
            let submission = try StorySubmission(title: title, url: url, text: text)
            Task {
                do {
                    let id = try await client.submitStory(submission)
                    if let id {
                        showToast("Submitted: \(id)", style: .success)
                    } else {
                        showToast("Submitted to Hacker News", style: .success)
                    }
                } catch {
                    handleActionError(error)
                }
            }
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    public func performDelete(id: ItemID) {
        Task {
            do {
                try await client.deleteItem(id: id)
                showToast("Deleted \(id)", style: .success)
                if case .thread(let threadView) = detail, threadView.root.id == id {
                    focus = .list
                    detail = .empty
                    refresh()
                } else if case .thread = detail {
                    reloadThread()
                }
                entries.removeAll { $0.id == id }
                notifyChange()
            } catch {
                handleActionError(error)
            }
        }
    }

    public func handleActionError(_ error: Error) {
        if let hnError = error as? HackerNewsError, case .unauthenticated = hnError {
            currentUser = nil
            openLogin(pendingSource: source.requiresAuthentication ? source : nil)
        }
        showToast(error.localizedDescription, style: .error)
    }

    // MARK: - Overlay input

    public func appendActiveInput(_ text: String) {
        guard !text.isEmpty else { return }
        switch overlay {
        case .commands(var palette):
            palette.query += text
            palette.selectedIndex = 0
            overlay = .commands(palette)
        case .search(var palette):
            palette.query += text
            overlay = .search(palette)
        case .login(var form):
            if form.focusedField == 0 {
                form.username += text
            } else {
                form.password += text
            }
            form.error = nil
            overlay = .login(form)
        case .prompt(var prompt):
            prompt.text += text
            overlay = .prompt(prompt)
        case .help, .confirm, .compose, .none:
            break
        }
    }

    public func backspaceActiveInput() {
        switch overlay {
        case .commands(var palette):
            if !palette.query.isEmpty { palette.query.removeLast() }
            palette.selectedIndex = 0
            overlay = .commands(palette)
        case .search(var palette):
            if !palette.query.isEmpty { palette.query.removeLast() }
            overlay = .search(palette)
        case .login(var form):
            if form.focusedField == 0, !form.username.isEmpty {
                form.username.removeLast()
            } else if form.focusedField == 1, !form.password.isEmpty {
                form.password.removeLast()
            }
            form.error = nil
            overlay = .login(form)
        case .prompt(var prompt):
            if !prompt.text.isEmpty { prompt.text.removeLast() }
            overlay = .prompt(prompt)
        case .help, .confirm, .compose, .none:
            break
        }
    }

    public func submitActiveInput() {
        switch overlay {
        case .commands:
            executeSelectedCommand()
        case .search(let palette):
            performSearch(palette.query)
        case .login:
            submitLogin()
        case .prompt:
            submitPrompt()
        case .help, .confirm, .compose, .none:
            break
        }
    }

    public func closeOverlay() {
        if case .compose = overlay {
            cancelCompose()
            return
        }
        overlay = nil
    }

    // MARK: - OS integration

    public func openURL(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try? process.run()
    }

    public func copyToClipboard(_ string: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        try? process.run()
        pipe.fileHandleForWriting.write(Data(string.utf8))
        try? pipe.fileHandleForWriting.close()
    }
}
