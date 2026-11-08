import Foundation
import Testing
import HackerNewsCore
@testable import HackerNewsAdapters

@Test func fileSessionStoreRoundTripsAndUsesPrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hn-session-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("session.json")
    let store = FileSessionStore(url: url)
    let session = StoredSession(
        cookie: "alice&tok123",
        username: UserID("alice"),
        savedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(try store.load() == nil)
    try store.save(session)

    let loaded = try #require(try store.load())
    #expect(loaded.cookie == "alice&tok123")
    #expect(loaded.username == UserID("alice"))
    #expect(loaded.savedAt == Date(timeIntervalSince1970: 1_700_000_000))

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue == 0o600)

    try store.clear()
    #expect(try store.load() == nil)
}
