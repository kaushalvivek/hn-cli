import Foundation
import HackerNewsCore
import HackerNewsAdapters

extension BrowserState {
    // MARK: - Opening composers

    public func requestComment() {
        guard let target = targetEntry else {
            showToast("Select a story or comment to reply to", style: .warning)
            return
        }
        let kind = ComposeKind.comment(parentID: target.id)
        openCompose(kind: kind, context: context(for: target, label: "Replying to"))
    }

    public func requestEdit() {
        guard let target = targetEntry else {
            showToast("Select an item to edit", style: .warning)
            return
        }
        let kind = ComposeKind.edit(itemID: target.id)
        openCompose(
            kind: kind,
            context: context(for: target, label: "Editing"),
            initialText: target.text ?? ""
        )
    }

    public func requestSubmitText(title: String) {
        let context = ComposeContext(
            storyTitle: title,
            itemID: nil,
            label: "New story"
        )
        openCompose(
            kind: .submitText(title: title),
            context: context
        )
    }

    private func context(for target: TUIEntry, label: String) -> ComposeContext {
        var storyTitle = target.storyTitle
        if storyTitle == nil, case .thread(let threadView) = detail {
            if threadView.root.kind == .story {
                storyTitle = TUIEntry(item: threadView.root).displayTitle
            }
        }
        if storyTitle == nil, target.kind == .story {
            storyTitle = target.displayTitle
        }

        return ComposeContext(
            author: target.author,
            storyTitle: storyTitle,
            excerpt: target.text,
            itemID: target.id,
            label: label
        )
    }

    public func openCompose(
        kind: ComposeKind,
        context: ComposeContext,
        initialText: String? = nil
    ) {
        let key = kind.draftKey
        let draft = drafts[key]?.text
        let text = draft ?? initialText ?? ""
        overlay = .compose(
            ComposeState(
                kind: kind,
                context: context,
                text: text,
                restoredDraft: draft != nil
            )
        )
        notifyChange()
    }

    // MARK: - Editing

    public func composeInsert(_ text: String) {
        mutateCompose { $0.insert(text) }
    }

    public func composeBackspace() {
        mutateCompose { $0.backspace() }
    }

    public func composeDeleteForward() {
        mutateCompose { $0.deleteForward() }
    }

    public func composeMoveLeft() {
        mutateCompose { $0.moveLeft() }
    }

    public func composeMoveRight() {
        mutateCompose { $0.moveRight() }
    }

    public func composeMoveUp() {
        mutateCompose { $0.moveUp() }
    }

    public func composeMoveDown() {
        mutateCompose { $0.moveDown() }
    }

    public func composeMoveHome() {
        mutateCompose { $0.moveHome() }
    }

    public func composeMoveEnd() {
        mutateCompose { $0.moveEnd() }
    }

    public func composePage(up: Bool) {
        mutateCompose { $0.movePage(up: up) }
    }

    private func mutateCompose(_ body: (inout ComposeState) -> Void) {
        guard case .compose(var compose) = overlay, !compose.isSubmitting else { return }
        body(&compose)
        overlay = .compose(compose)
        notifyChange()
    }

    // MARK: - Cancel, drafts, external editor

    public func cancelCompose() {
        guard case .compose(let compose) = overlay, !compose.isSubmitting else { return }

        let key = compose.kind.draftKey
        if compose.trimmedText.isEmpty {
            drafts.removeValue(forKey: key)
        } else {
            drafts[key] = ComposeDraftRecord(text: compose.text, savedAt: Date())
        }
        persistDrafts()
        overlay = nil
        showToast(compose.trimmedText.isEmpty ? "Cancelled" : "Draft saved", style: .info)
        notifyChange()
    }

    public func saveActiveDraft() {
        guard case .compose(let compose) = overlay else { return }
        if compose.trimmedText.isEmpty {
            drafts.removeValue(forKey: compose.kind.draftKey)
        } else {
            drafts[compose.kind.draftKey] = ComposeDraftRecord(
                text: compose.text,
                savedAt: Date()
            )
        }
        persistDrafts()
    }

    public func openExternalEditorForCompose() {
        guard case .compose(let compose) = overlay, !compose.isSubmitting else { return }
        drafts[compose.kind.draftKey] = ComposeDraftRecord(
            text: compose.text,
            savedAt: Date()
        )
        persistDrafts()
        pendingEditor = .compose(initialText: compose.text)
    }

    public func handleExternalEditorResult(text: String) {
        guard case .compose(var compose) = overlay else { return }
        compose.text = text
        compose.cursor = text.count
        compose.error = nil
        compose.restoredDraft = false
        overlay = .compose(compose)
        drafts[compose.kind.draftKey] = ComposeDraftRecord(text: text, savedAt: Date())
        persistDrafts()
        notifyChange()
    }

    private func persistDrafts() {
        try? draftStore.save(drafts)
    }

    // MARK: - Submit

    public func submitCompose() {
        guard case .compose(var compose) = overlay, !compose.isSubmitting else { return }

        let text = compose.trimmedText
        guard !text.isEmpty else {
            compose.error = "Write something first"
            overlay = .compose(compose)
            notifyChange()
            return
        }

        compose.isSubmitting = true
        compose.error = nil
        overlay = .compose(compose)
        drafts[compose.kind.draftKey] = ComposeDraftRecord(
            text: compose.text,
            savedAt: Date()
        )
        persistDrafts()
        notifyChange()

        let kind = compose.kind
        let rawText = compose.text

        Task {
            do {
                switch kind {
                case .comment(let parentID):
                    let id = try await client.submitComment(
                        CommentSubmission(parentID: parentID, text: rawText)
                    )
                    completeCompose(kind: kind)
                    showToast(
                        id.map { "Comment posted: \($0)" } ?? "Comment posted",
                        style: .success
                    )
                    await insertPostedComment(id: id, parentID: parentID)

                case .edit(let itemID):
                    try await client.editItem(id: itemID, text: rawText)
                    completeCompose(kind: kind)
                    showToast("Edited \(itemID)", style: .success)
                    applyEditedText(id: itemID, text: rawText)

                case .submitText(let title):
                    let id = try await client.submitStory(
                        StorySubmission(title: title, text: rawText)
                    )
                    completeCompose(kind: kind)
                    if let id {
                        showToast("Submitted: \(id)", style: .success)
                    } else {
                        showToast("Submitted to Hacker News", style: .success)
                    }
                }
            } catch {
                guard case .compose(var current) = overlay else { return }
                current.isSubmitting = false
                current.error = error.localizedDescription
                overlay = .compose(current)
                drafts[kind.draftKey] = ComposeDraftRecord(
                    text: current.text,
                    savedAt: Date()
                )
                persistDrafts()
                notifyChange()
            }
        }
    }

    private func completeCompose(kind: ComposeKind) {
        drafts.removeValue(forKey: kind.draftKey)
        persistDrafts()
        overlay = nil
        notifyChange()
    }

    private func insertPostedComment(id: ItemID?, parentID: ItemID) async {
        if let id, let item = try? await client.item(id: id) {
            if case .thread(let threadView) = detail,
               threadView.insert(item, under: parentID)
            {
                detail = .thread(threadView)
                focus = .detail
                ensureSelectionVisible()
                notifyChange()
                return
            }
        }

        if case .thread = detail {
            reloadThread()
        }
    }

    private func applyEditedText(id: ItemID, text: String) {
        guard case .thread(let threadView) = detail else { return }
        if threadView.root.id == id {
            reloadThread()
            return
        }
        if threadView.updateText(id: id, text: text) {
            detail = .thread(threadView)
            focus = .detail
            ensureSelectionVisible()
            notifyChange()
        } else {
            reloadThread()
        }
    }
}
