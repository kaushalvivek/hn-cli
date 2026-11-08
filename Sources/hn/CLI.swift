import Darwin
import Foundation
import ArgumentParser

enum SecretInput {
    static func username(_ provided: String?) throws -> String {
        if let provided, !provided.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return provided.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        FileHandle.standardError.write(Data("Username: ".utf8))
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            throw ValidationError("A username is required")
        }
        return line
    }

    static func password(fromStdin: Bool) throws -> String {
        if fromStdin {
            guard let line = readLine(strippingNewline: true), !line.isEmpty else {
                throw ValidationError("No password was read from stdin")
            }
            return line
        }

        if let environment = ProcessInfo.processInfo.environment["HN_PASSWORD"], !environment.isEmpty {
            return environment
        }

        let prompt = "Password: "
        guard let pointer = prompt.withCString({ getpass($0) }) else {
            throw ValidationError("Could not read the password")
        }
        let password = String(cString: pointer)
        guard !password.isEmpty else {
            throw ValidationError("Password must not be empty")
        }
        return password
    }
}

enum TextInput {
    static func resolve(_ provided: String?) throws -> String {
        if let provided {
            if provided == "-" {
                return try readStdin()
            }
            return provided
        }

        if isatty(STDIN_FILENO) == 0 {
            return try readStdin()
        }

        return try Editor.edit(initial: "")
    }

    static func readStdin() throws -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ValidationError("No text was provided")
        }
        return text
    }
}

enum Editor {
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
            throw ValidationError("Editor exited with status \(process.terminationStatus)")
        }

        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ValidationError("Aborting: the text is empty")
        }
        return text
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

func confirm(_ message: String) -> Bool {
    FileHandle.standardError.write(Data("\(message) [y/N] ".utf8))
    guard let line = readLine(strippingNewline: true) else { return false }
    return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
}
