import Foundation

struct ComposeDraftRecord: Codable, Equatable, Sendable {
    var text: String
    var savedAt: Date
}

struct ComposeDraftStore: Sendable {
    let url: URL

    init(url: URL = ComposeDraftStore.defaultURL) {
        self.url = url
    }

    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["HN_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("drafts.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("hn", isDirectory: true)
            .appendingPathComponent("drafts.json")
    }

    func load() throws -> [String: ComposeDraftRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: ComposeDraftRecord].self, from: data)
    }

    func save(_ drafts: [String: ComposeDraftRecord]) throws {
        guard !drafts.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(drafts)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
