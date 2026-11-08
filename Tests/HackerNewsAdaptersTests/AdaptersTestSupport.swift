import Foundation
import HackerNewsCore
@testable import HackerNewsAdapters

actor MockHTTPClient: HTTPClient {
    typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private let handler: Handler
    private var captured: [HTTPRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        captured.append(request)
        return try await handler(request)
    }

    func requests() -> [HTTPRequest] {
        captured
    }
}

func makeResponse(
    for request: HTTPRequest,
    status: Int = 200,
    headers: [String: String] = [:],
    body: String
) -> HTTPResponse {
    HTTPResponse(
        statusCode: status,
        headers: headers,
        body: Data(body.utf8),
        finalURL: request.url
    )
}

func query(_ request: HTTPRequest, _ name: String) -> String? {
    URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == name })?
        .value
}

func bodyText(_ request: HTTPRequest) -> String {
    guard let body = request.body else { return "" }
    return String(decoding: body, as: UTF8.self)
}

enum Fixtures {
    static let votePage = """
    <html><body>
    <a href="logout?auth=abc123">logout</a>
    <a id="up_1" href="vote?id=1&amp;how=up&amp;auth=abc123&amp;goto=item%3Fid%3D1">upvote</a>
    <a id="un_1" href="vote?id=1&amp;how=un&amp;auth=abc123&amp;goto=item%3Fid%3D1">unvote</a>
    </body></html>
    """

    static let votePageAlreadyVoted = """
    <html><body>
    <a href="logout?auth=abc123">logout</a>
    <a id="un_1" href="vote?id=1&amp;how=un&amp;auth=abc123&amp;goto=item%3Fid%3D1">unvote</a>
    </body></html>
    """

    static let commentFormPage = """
    <html><body>
    <form method="post" action="comment">
      <input type="hidden" name="parent" value="1">
      <input type="hidden" name="goto" value="item?id=1">
      <input type="hidden" name="hmac" value="hmac123">
      <textarea name="text"></textarea>
    </form>
    </body></html>
    """

    static let submitFormPage = """
    <html><body>
    <form method="post" action="/r">
      <input type="hidden" name="fnid" value="fnid123">
      <input type="hidden" name="fnop" value="submit-page">
      <input type="text" name="title">
      <input type="text" name="url">
      <textarea name="text"></textarea>
    </form>
    </body></html>
    """

    static let editFormPage = """
    <html><body>
    <form method="post" action="xedit">
      <input type="hidden" name="hmac" value="hmac123">
      <input type="hidden" name="id" value="1">
      <textarea name="text"></textarea>
    </form>
    </body></html>
    """

    static let deleteFormPage = """
    <html><body>
    <form method="post" action="xdelete">
      <input type="hidden" name="fnid" value="fnid123">
      <input type="hidden" name="fnop" value="delete-page">
    </form>
    </body></html>
    """

    static let feedPage = """
    <html><body>
    <table>
      <tr class="athing" id="1"><td>one</td></tr>
      <tr class="athing" id="2"><td>two</td></tr>
      <tr class="athing" id="2"><td>duplicate</td></tr>
    </table>
    <a href="newcomments?next=2&amp;n=31" class="morelink" rel="next">More</a>
    </body></html>
    """

    static let feedPageWithoutMore = """
    <html><body>
    <table>
      <tr class="athing" id="3"><td>three</td></tr>
    </table>
    </body></html>
    """

    static let leadersPage = """
    <html><body>
    <table>
      <tr class="athing"><td align="right">1.</td><td><a href="user?id=alice">alice</a></td><td align="right"></td></tr>
      <tr class="athing"><td align="right">2.</td><td><a href="user?id=bob">bob</a></td><td align="right">12345</td></tr>
    </table>
    </body></html>
    """

    static let loginSuccessHeaders = [
        "set-cookie": "user=alice&abc123def456; Path=/; HttpOnly; Secure"
    ]
}
