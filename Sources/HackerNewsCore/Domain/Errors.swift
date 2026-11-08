import Foundation

/// Errors surfaced by Hacker News domain operations.
public enum HackerNewsError: Error, Sendable, Equatable {
    /// The caller supplied a value the domain cannot accept.
    case invalidInput(String)

    /// The requested item, user, or feed does not exist.
    case notFound(Resource)

    /// The operation needs a signed-in session.
    case unauthenticated

    /// The supplied username or password was rejected.
    case invalidCredentials

    /// The signed-in account is not allowed to perform the operation.
    case unauthorized

    /// The operation is modeled but not supported by the available source.
    case unsupported(String)

    /// The source asked us to slow down.
    case rateLimited(retryAfter: Duration?)

    /// The source returned an unexpected status.
    case server(statusCode: Int)

    /// A transport-level failure (DNS, connection, TLS, timeout, ...).
    case transport(String)

    /// A response could not be decoded into the domain.
    case decoding(String)

    /// The task was cancelled.
    case cancelled

    public enum Resource: Sendable, Hashable {
        case item(ItemID)
        case user(UserID)
        case feed(Feed)
    }
}

extension HackerNewsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return message
        case .notFound(.item(let id)):
            return "Item \(id) was not found."
        case .notFound(.user(let id)):
            return "User \(id) was not found."
        case .notFound(.feed):
            return "That feed was not found."
        case .unauthenticated:
            return "Not logged in. Run `hn login` first."
        case .invalidCredentials:
            return "Invalid Hacker News username or password."
        case .unauthorized:
            return "That action is not allowed for this account."
        case .unsupported(let message):
            return message
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Hacker News rate-limited the request. Retry in \(retryAfter)."
            }
            return "Hacker News rate-limited the request. Try again later."
        case .server(let statusCode):
            return "Hacker News returned HTTP \(statusCode)."
        case .transport(let message):
            return message
        case .decoding(let message):
            return "Could not read the Hacker News response: \(message)"
        case .cancelled:
            return "Cancelled."
        }
    }
}
