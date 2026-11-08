import Foundation
import HackerNewsCore

/// A minimal HTTP request abstraction shared by all adapters.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var followRedirects: Bool
    public var timeout: TimeInterval?

    public init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        followRedirects: Bool = true,
        timeout: TimeInterval? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.followRedirects = followRedirects
        self.timeout = timeout
    }
}

/// A minimal HTTP response abstraction.
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    public let finalURL: URL

    public init(statusCode: Int, headers: [String: String], body: Data, finalURL: URL) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }

    public var text: String {
        String(decoding: body, as: UTF8.self)
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// URLSession-backed HTTP client with manual cookie management.
///
/// Cookies are deliberately not stored by URLSession; the site adapter owns the
/// Hacker News session cookie so it can persist it explicitly.
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body

        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }

        // URLSession follows redirects by default for the shared session. For
        // requests that need to observe the redirect response itself (login),
        // use a one-off session with a delegate that refuses the redirect.
        let session = request.followRedirects
            ? self.session
            : Self.makeNoRedirectSession(timeout: request.timeout ?? 30)
        defer {
            if !request.followRedirects {
                session.finishTasksAndInvalidate()
            }
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HackerNewsError.transport("Response was not HTTP")
            }

            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                guard let key = key as? String, let value = value as? String else { continue }
                headers[key.lowercased()] = value
            }

            return HTTPResponse(
                statusCode: httpResponse.statusCode,
                headers: headers,
                body: data,
                finalURL: httpResponse.url ?? request.url
            )
        } catch let error as HackerNewsError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw HackerNewsError.cancelled
        } catch {
            throw HackerNewsError.transport(error.localizedDescription)
        }
    }

    private static func makeNoRedirectSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(
            configuration: configuration,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum FormEncoding {
    /// Encodes a dictionary as `application/x-www-form-urlencoded`.
    public static func encode(_ fields: [String: String]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    public static func escape(_ string: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
