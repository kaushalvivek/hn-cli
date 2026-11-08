import Foundation
import HackerNewsCore
import SwiftSoup

extension HackerNewsSiteClient: AccountProvider {
    public func vote(on itemID: ItemID, direction: VoteDirection) async throws {
        _ = try requireSession()

        let referer = "item?id=\(itemID.rawValue)"
        let page = try await request(referer)
        try await ensureNotLoginPage(page)
        let document = try HTMLSupport.document(from: page.text)

        let linkID: String
        switch direction {
        case .up: linkID = "up_\(itemID.rawValue)"
        case .down: linkID = "down_\(itemID.rawValue)"
        case .unvote: linkID = "un_\(itemID.rawValue)"
        }

        if let link = try document.select("a[id=\(linkID)]").first() {
            let href = cleanHref(try link.attr("href"))
            let response = try await request(href, referer: referer)
            try await ensureActionSucceeded(response, action: "vote")
            return
        }

        guard page.text.contains("logout?auth=") else {
            throw HackerNewsError.unauthenticated
        }

        // `un_<id>` means a vote already exists, but it does not reveal whether
        // it is an upvote or a downvote. For a removal, there is nothing to do;
        // for an up/down change, use the POST endpoint to set the desired state.
        if direction == .unvote {
            return
        }

        var fields = [
            "id": String(itemID.rawValue),
            "how": direction == .up ? "up" : "down",
        ]
        if let token = await authToken() {
            fields["auth"] = token
        }

        let response = try await request(
            "vote",
            method: "POST",
            fields: fields,
            referer: referer
        )
        try await ensureActionSucceeded(response, action: "vote")
    }

    public func submitStory(_ submission: StorySubmission) async throws -> ItemID? {
        _ = try requireSession()

        let form = try await findForm(
            paths: ["submitlink", "submit"],
            containingInput: "fnid"
        )

        var fields = form.fields.hiddenFields
        fields["title"] = submission.title
        fields["url"] = submission.url?.absoluteString ?? ""
        fields["text"] = submission.text ?? ""
        if fields["fnop"] == nil {
            fields["fnop"] = "submit-page"
        }

        let response = try await request(
            "r",
            method: "POST",
            fields: fields,
            referer: form.path
        )
        try await ensureActionSucceeded(response, action: "submit")
        return parseItemID(from: response.finalURL)
    }

    public func submitComment(_ submission: CommentSubmission) async throws -> ItemID? {
        _ = try requireSession()

        let parentID = submission.parentID.rawValue
        let referer = "item?id=\(parentID)"
        let page = try await request(referer)
        try await ensureNotLoginPage(page)
        let document = try HTMLSupport.document(from: page.text)

        guard let form = try HTMLSupport.form(in: document, containingTextArea: "text")
            ?? HTMLSupport.form(in: document, containingInput: "hmac")
        else {
            throw HackerNewsError.unsupported("No comment form found for item \(parentID)")
        }

        var fields = form.hiddenFields
        fields["text"] = submission.text
        // Do not trust a stale hidden parent from a reused form page. The
        // composer target is authoritative.
        fields["parent"] = String(parentID)
        fields["goto"] = referer

        let path = form.action.isEmpty || form.action == "#" ? "comment" : form.action
        let response = try await request(
            cleanHref(path),
            method: "POST",
            fields: fields,
            referer: referer
        )
        try await ensureActionSucceeded(response, action: "comment")
        return parseCommentID(from: response.finalURL)
    }

    public func editItem(id: ItemID, text: String) async throws {
        _ = try requireSession()

        let referer = "edit?id=\(id.rawValue)"
        let page = try await request(referer)
        try await ensureNotLoginPage(page)
        let document = try HTMLSupport.document(from: page.text)

        guard let form = try HTMLSupport.form(in: document, containingTextArea: "text") else {
            throw HackerNewsError.unsupported("No edit form found for item \(id)")
        }

        var fields = form.hiddenFields
        fields["id"] = String(id.rawValue)
        fields["text"] = text

        let path = form.action.isEmpty || form.action == "#" ? "xedit" : form.action
        let response = try await request(
            cleanHref(path),
            method: "POST",
            fields: fields,
            referer: referer
        )
        try await ensureActionSucceeded(response, action: "edit")
    }

    public func deleteItem(id: ItemID) async throws {
        _ = try requireSession()

        let goto = FormEncoding.escape("item?id=\(id.rawValue)")
        let referer = "delete-confirm?id=\(id.rawValue)&goto=\(goto)"
        let page = try await request(referer)
        try await ensureNotLoginPage(page)
        let document = try HTMLSupport.document(from: page.text)

        guard let form = try HTMLSupport.form(in: document, containingInput: "fnid")
            ?? HTMLSupport.form(in: document, actionContaining: "xdelete")
        else {
            throw HackerNewsError.unsupported("No delete form found for item \(id)")
        }

        var fields = form.hiddenFields
        fields["d"] = "Yes"

        let path = form.action.isEmpty || form.action == "#" ? "xdelete" : form.action
        let response = try await request(
            cleanHref(path),
            method: "POST",
            fields: fields,
            referer: referer
        )
        try await ensureActionSucceeded(response, action: "delete")
    }

    public func setFavorite(_ isFavorite: Bool, on itemID: ItemID) async throws {
        try await toggle(
            path: "fave",
            on: itemID,
            enabled: isFavorite
        )
    }

    public func setHidden(_ isHidden: Bool, on itemID: ItemID) async throws {
        try await toggle(
            path: "hide",
            on: itemID,
            enabled: isHidden
        )
    }

    public func flag(itemID: ItemID, reason: String) async throws {
        _ = try requireSession()

        var fields = ["id": String(itemID.rawValue)]
        if !reason.isEmpty {
            fields["reason"] = reason
        }
        if let token = await authToken() {
            fields["auth"] = token
        }

        let response = try await request(
            "flag",
            method: "POST",
            fields: fields,
            referer: "item?id=\(itemID.rawValue)"
        )
        try await ensureActionSucceeded(response, action: "flag")
    }

    public func unflag(itemID: ItemID) async throws {
        _ = try requireSession()

        var fields = [
            "id": String(itemID.rawValue),
            "un": "t",
        ]
        if let token = await authToken() {
            fields["auth"] = token
        }

        let response = try await request(
            "flag",
            method: "POST",
            fields: fields,
            referer: "item?id=\(itemID.rawValue)"
        )
        try await ensureActionSucceeded(response, action: "unflag")
    }

    // MARK: - Helpers

    private func toggle(path: String, on itemID: ItemID, enabled: Bool) async throws {
        _ = try requireSession()

        var fields = ["id": String(itemID.rawValue)]
        if !enabled {
            fields["un"] = "t"
        }
        if let token = await authToken() {
            fields["auth"] = token
        }

        let referer = "item?id=\(itemID.rawValue)"
        let response = try await request(
            path,
            method: "POST",
            fields: fields,
            referer: referer
        )
        try await ensureActionSucceeded(response, action: path)
    }

    private func findForm(
        paths: [String],
        containingInput name: String
    ) async throws -> (fields: ParsedForm, path: String) {
        for path in paths {
            let response = try await request(path)
            try await ensureNotLoginPage(response)
            let document = try HTMLSupport.document(from: response.text)
            if let form = try HTMLSupport.form(in: document, containingInput: name) {
                return (form, path)
            }
        }
        throw HackerNewsError.unsupported("Could not find the Hacker News form")
    }

    private func cleanHref(_ href: String) -> String {
        href.replacingOccurrences(of: "&amp;", with: "&")
    }

    private func parseItemID(from url: URL) -> ItemID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?
            .first(where: { $0.name == "id" })?
            .value
            .flatMap(Int.init)
            .flatMap(ItemID.init(validating:))
    }

    private func parseCommentID(from url: URL) -> ItemID? {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              let value = Int(fragment)
        else {
            return nil
        }
        return ItemID(validating: value)
    }

    private func ensureActionSucceeded(
        _ response: HTTPResponse,
        action: String
    ) async throws {
        try await ensureNotLoginPage(response)

        if response.statusCode >= 400 {
            throw HackerNewsError.server(statusCode: response.statusCode)
        }

        let text = response.text.lowercased()
        if text.contains("unknown or expired link") {
            throw HackerNewsError.invalidInput("The Hacker News form expired; try again")
        }
        if text.contains("you have to wait") || text.contains("posting too fast") {
            throw HackerNewsError.rateLimited(retryAfter: nil)
        }
        if text.contains("already been submitted") {
            throw HackerNewsError.invalidInput("That link has already been submitted to Hacker News")
        }
        if text.contains("please confirm") {
            throw HackerNewsError.invalidInput("Hacker News asked for confirmation before accepting this submission")
        }
        if text.contains("not able to serve your requests") || text.contains("couldn't serve your request") {
            throw HackerNewsError.rateLimited(retryAfter: nil)
        }
        if text.contains("validation required") {
            throw HackerNewsError.unsupported("Hacker News requires browser validation for this action")
        }
        if text.contains("bad login") {
            throw HackerNewsError.unauthenticated
        }
        if text.contains("you have to be logged in") || text.contains("not logged in") {
            throw HackerNewsError.unauthenticated
        }
    }
}
