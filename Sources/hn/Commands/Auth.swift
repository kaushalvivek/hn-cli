import ArgumentParser
import HackerNewsCore
import HackerNewsAdapters

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Log in to Hacker News and save the session."
    )

    @Option(name: .long, help: "Hacker News username. Prompted if omitted.")
    var username: String?

    @Flag(name: .long, help: "Read the password from standard input.")
    var passwordStdin = false

    func run() async throws {
        let username = try SecretInput.username(self.username)
        let password = try SecretInput.password(fromStdin: passwordStdin)
        let credentials = try Credentials(username: username, password: password)

        let client = HackerNewsClient()
        let session = try await client.logIn(credentials)
        Output().write("Logged in as \(session.userID.rawValue).")
    }
}

struct Signup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "signup",
        abstract: "Create a Hacker News account and save the session."
    )

    @Option(name: .long, help: "Username for the new account. Prompted if omitted.")
    var username: String?

    @Flag(name: .long, help: "Read the password from standard input.")
    var passwordStdin = false

    func run() async throws {
        let username = try SecretInput.username(self.username)
        let password = try SecretInput.password(fromStdin: passwordStdin)
        let credentials = try Credentials(username: username, password: password)

        let client = HackerNewsClient()
        let session = try await client.signUp(credentials)
        Output().write("Created account and logged in as \(session.userID.rawValue).")
    }
}

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Log out of Hacker News and remove the saved session."
    )

    func run() async throws {
        let client = HackerNewsClient()
        try await client.logOut()
        Output().write("Logged out.")
    }
}

struct Whoami: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whoami",
        abstract: "Show the signed-in Hacker News account."
    )

    func run() async throws {
        let client = HackerNewsClient()
        guard let session = try await client.validateSession() else {
            Output().write("Not logged in.")
            throw ExitCode.failure
        }
        Output().write(session.userID.rawValue)
    }
}
