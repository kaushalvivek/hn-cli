import Foundation
import Testing
@testable import HackerNewsAdapters
import HackerNewsCore

@Test func htmlFindsItemIDsInOrderWithoutDuplicates() throws {
    let document = try HTMLSupport.document(from: Fixtures.feedPage)
    #expect(try HTMLSupport.itemIDs(in: document) == [ItemID(1), ItemID(2)])
}

@Test func htmlFindsMoreLinkAndDecodesAmpersand() throws {
    let document = try HTMLSupport.document(from: Fixtures.feedPage)
    #expect(try HTMLSupport.moreLink(in: document) == "newcomments?next=2&n=31")
}

@Test func htmlFindsAuthTokenInEscapedHref() throws {
    #expect(HTMLSupport.authToken(in: Fixtures.votePage) == "abc123")
}

@Test func htmlParsesHiddenFormFields() throws {
    let document = try HTMLSupport.document(from: Fixtures.submitFormPage)
    let form = try #require(try HTMLSupport.form(in: document, containingInput: "fnid"))
    #expect(form.action == "/r")
    #expect(form.method == "post")
    #expect(form.hiddenFields["fnid"] == "fnid123")
    #expect(form.hiddenFields["fnop"] == "submit-page")
    #expect(form.hiddenFields["title"] == nil)
}

@Test func htmlFindsTextAreaForm() throws {
    let document = try HTMLSupport.document(from: Fixtures.commentFormPage)
    let form = try #require(try HTMLSupport.form(in: document, containingTextArea: "text"))
    #expect(form.action == "comment")
    #expect(form.hiddenFields["hmac"] == "hmac123")
    #expect(form.hiddenFields["parent"] == "1")
    #expect(form.textAreaName == "text")
}

@Test func htmlParsesLeaders() throws {
    let document = try HTMLSupport.document(from: Fixtures.leadersPage)
    let leaders = try HTMLSupport.leaders(in: document)
    #expect(leaders == [
        LeaderboardEntry(userID: UserID("alice"), karma: 0),
        LeaderboardEntry(userID: UserID("bob"), karma: 12345),
    ])
}

@Test func htmlDetectsLoginPage() throws {
    let document = try HTMLSupport.document(from: """
    <form method="post"><input name="acct"><input type="password" name="pw"></form>
    """)
    #expect(try HTMLSupport.isLoginPage(document))
}

@Test func htmlTextRendererHandlesParagraphsAndEntities() {
    let text = HTMLTextRenderer.plainText("<p>Hello &amp; welcome.</p><p>Second <i>paragraph</i>.</p>")
    #expect(text == "Hello & welcome.\n\nSecond paragraph.")
}

@Test func htmlTextRendererKeepsCodeBlocks() {
    let text = HTMLTextRenderer.plainText("Run this:<p><pre><code>swift test\nswift build</code></pre>")
    #expect(text.contains("swift test"))
    #expect(text.contains("swift build"))
}

@Test func htmlTextRendererAddsURLForGenericLinkText() {
    let text = HTMLTextRenderer.plainText("<p>See <a href=\"https://example.com\">this</a>.</p>")
    #expect(text.contains("this (https://example.com)"))
}
