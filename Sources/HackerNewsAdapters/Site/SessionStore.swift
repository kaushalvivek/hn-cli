import Foundation
import HackerNewsCore

/// A persisted Hacker News session. Only the `user` cookie is stored; passwords
/// are never persisted.
public struct StoredSession: Codable, Sendable, Equatable {
    public let cookie: String
    public let username: UserID
    public let savedAt: Date

    public init(cookie: String, username: UserID, savedAt: Date = Date()) {
        self.cookie = cookie
        self.username = username
        self.savedAt = savedAt
    }
}

public protocol SessionStore: Sendable {
    func load() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func clear() throws
}

/// Stores the session in a JSON file readable only by the current user.
public struct FileSessionStore: SessionStore {
    public let url: URL

    public init(url: URL = FileSessionStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["HN_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("session.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("hn", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    public func load() throws -> StoredSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// In-memory store used by tests and by the iOS app before Keychain wiring.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?

    public init(session: StoredSession? = nil) {
        self.session = session
    }

    public func load() throws -> StoredSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public func save(_ session: StoredSession) throws {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        session = nil
    }
}
