import Foundation

enum TUIEditorError: Error, LocalizedError {
    case editorFailed(Int32)
    case empty

    var errorDescription: String? {
        switch self {
        case .editorFailed(let status):
            return "Editor exited with status \(status)"
        case .empty:
            return "Aborted: the text is empty"
        }
    }
}

enum TUIEditor {
    static func edit(initial: String = "") throws -> String {
        let editor = ProcessInfo.processInfo.environment["VISUAL"]
            ?? ProcessInfo.processInfo.environment["EDITOR"]
            ?? "vi"

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-\(UUID().uuidString).txt")
        try initial.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(editor) \(shellQuote(url.path))"]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TUIEditorError.editorFailed(process.terminationStatus)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TUIEditorError.empty
        }
        return text
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
