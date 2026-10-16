import Foundation
import os
import VaultCore

/// A scripted ``HTTPTransporting`` for tests and previews (v0.8.0, like GitHubKit's
/// `FakeCommandRunner`).
///
/// - Matches each request by method, path prefix and, optionally, host: queued one-shot
///   responses first (FIFO among those that match), then persistent stubs and handlers (the
///   latest added first). Unmatched requests throw ``DestinationError/invalidRequest(code:)``
///   with ``DestinationError/LocalCode/fakeUnmatched`` and are listed in ``unmatchedRequests``.
/// - Records every request: method, URL, header names, the value-free headers, the bearer
///   token and a copy of the body. Recorded tokens and bodies are test data; never use the
///   fake with real secrets.
/// - Applies the real transport's host allowlist, so a test cannot pass with a URL production
///   would refuse.
public final class FakeHTTPTransport: HTTPTransporting, Sendable {
    /// One recorded request.
    public struct RecordedRequest: Sendable {
        public let method: HTTPMethod
        public let url: URL
        /// Every header name the transport would send, lowercased (`authorization` when a
        /// bearer token is set).
        public let headerNames: Set<String>
        /// The value-free headers, as given.
        public let headers: [String: String]
        /// The bearer token as text (test data).
        public let bearerToken: String?
        /// A copy of the body (test data).
        public let body: Data?

        /// The path, percent-encoded as sent.
        public var path: String {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        }

        /// The query string, percent-encoded as sent, or nil.
        public var query: String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        }

        /// The body as UTF-8 text (test data).
        public var bodyText: String? {
            body.map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// A scripted answer.
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data
        /// Throw this instead of answering (network, timeout, ...).
        public var error: DestinationError?

        public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data(), error: DestinationError? = nil) {
            self.status = status
            self.headers = headers
            self.body = body
            self.error = error
        }

        /// `status` with a JSON body.
        public static func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers, body: Data(body.utf8))
        }

        /// `status` with no body.
        public static func status(_ status: Int, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers)
        }

        /// A transport failure.
        public static func failure(_ error: DestinationError) -> Response {
            Response(error: error)
        }
    }

    private struct Matcher: Sendable {
        let method: HTTPMethod?
        let pathPrefix: String
        let host: String?

        func matches(_ request: RecordedRequest) -> Bool {
            (method == nil || method == request.method)
                && request.path.hasPrefix(pathPrefix)
                && (host == nil || host?.lowercased() == request.url.host?.lowercased())
        }
    }

    private struct Entry: Sendable {
        let matcher: Matcher
        let respond: @Sendable (RecordedRequest) -> Response
    }

    private struct State: Sendable {
        var queued: [Entry] = []
        var stubs: [Entry] = []
        var requests: [RecordedRequest] = []
        var unmatched: [RecordedRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Queues a one-shot `response` for the next request that matches.
    public func enqueue(_ response: Response, method: HTTPMethod? = nil, pathPrefix: String = "/", host: String? = nil) {
        let entry = Entry(matcher: Matcher(method: method, pathPrefix: pathPrefix, host: host)) { _ in response }
        state.withLock { $0.queued.append(entry) }
    }

    /// Answers every matching request with `response` (checked after the queue; the latest stub
    /// wins).
    public func stub(_ response: Response, method: HTTPMethod? = nil, pathPrefix: String = "/", host: String? = nil) {
        respond(method: method, pathPrefix: pathPrefix, host: host) { _ in response }
    }

    /// Answers every matching request with `handler`'s response (a stateful stand-in).
    public func respond(
        method: HTTPMethod? = nil,
        pathPrefix: String = "/",
        host: String? = nil,
        with handler: @escaping @Sendable (RecordedRequest) -> Response
    ) {
        let entry = Entry(matcher: Matcher(method: method, pathPrefix: pathPrefix, host: host), respond: handler)
        state.withLock { $0.stubs.insert(entry, at: 0) }
    }

    /// Every request so far, in order.
    public var requests: [RecordedRequest] {
        state.withLock { $0.requests }
    }

    /// Requests nothing matched.
    public var unmatchedRequests: [RecordedRequest] {
        state.withLock { $0.unmatched }
    }

    public func send(_ request: HTTPRequestModel) async throws(DestinationError) -> HTTPResponseModel {
        guard DestinationHostPolicy.isAllowed(request.url) else { throw .disallowedHost }
        var headerNames = Set(request.headers.keys.map { $0.lowercased() })
        if request.bearerToken != nil {
            headerNames.insert(HTTPHeader.authorization.lowercased())
        }
        let recorded = RecordedRequest(
            method: request.method,
            url: request.url,
            headerNames: headerNames,
            headers: request.headers,
            bearerToken: request.bearerToken?.withUnsafeBytes { String(decoding: $0, as: UTF8.self) },
            body: request.body?.withUnsafeBytes { Data($0) }
        )
        let entry = state.withLock { state -> Entry? in
            state.requests.append(recorded)
            if let index = state.queued.firstIndex(where: { $0.matcher.matches(recorded) }) {
                return state.queued.remove(at: index)
            }
            if let stub = state.stubs.first(where: { $0.matcher.matches(recorded) }) {
                return stub
            }
            state.unmatched.append(recorded)
            return nil
        }
        guard let entry else { throw .invalidRequest(code: DestinationError.LocalCode.fakeUnmatched) }
        let response = entry.respond(recorded)
        if let error = response.error {
            throw error
        }
        var body = response.body
        return HTTPResponseModel(status: response.status, headers: response.headers, body: SecretBytes(wipingSource: &body))
    }
}
