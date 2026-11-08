import Foundation
import Testing
@testable import HackerNewsCore

@Test func storySubmissionAcceptsALink() throws {
    let submission = try StorySubmission(
        title: "  A link  ",
        url: URL(string: "https://example.com")
    )
    #expect(submission.title == "A link")
    #expect(submission.url == URL(string: "https://example.com"))
    #expect(submission.text == nil)
}

@Test func storySubmissionAcceptsText() throws {
    let submission = try StorySubmission(title: "Ask HN: A question?", text: "  Hello  ")
    #expect(submission.text == "Hello")
    #expect(submission.url == nil)
}

@Test func storySubmissionRejectsEmptyTitle() {
    #expect(throws: HackerNewsError.self) {
        try StorySubmission(title: "   ", text: "body")
    }
}

@Test func storySubmissionRequiresURLOrText() {
    #expect(throws: HackerNewsError.self) {
        try StorySubmission(title: "A title")
    }
    #expect(throws: HackerNewsError.self) {
        try StorySubmission(title: "A title", text: "   ")
    }
}

@Test func commentSubmissionTrimsText() throws {
    let submission = try CommentSubmission(parentID: ItemID(1), text: "  hello  ")
    #expect(submission.text == "hello")
    #expect(submission.parentID == ItemID(1))
}

@Test func commentSubmissionRejectsEmptyText() {
    #expect(throws: HackerNewsError.self) {
        try CommentSubmission(parentID: ItemID(1), text: " \n ")
    }
}

@Test func credentialsRequireUsernameAndPassword() {
    #expect(throws: HackerNewsError.self) {
        try Credentials(username: "  ", password: "secret")
    }
    #expect(throws: HackerNewsError.self) {
        try Credentials(username: "alice", password: "")
    }
}
