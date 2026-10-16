import Foundation
import VaultCore

/// The HTTP methods the destination clients use.
public enum HTTPMethod: String, Sendable, Hashable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// One HTTPS request to a provider (v0.8.0, tasks/todo.md R4).
///
/// - Values travel only in ``body``; the credential only in ``bearerToken``. Neither ever goes
///   into ``url`` or ``headers``.
/// - The caller owns ``body`` and ``bearerToken`` and wipes them after the last attempt;
///   transports copy what they send.
/// - The textual representations show only the method, the host and the body size.
public struct HTTPRequestModel: Sendable {
    public var method: HTTPMethod
    public var url: URL
    /// Value-free headers (`Accept`, `Content-Type`). Reserved names (`Authorization`,
    /// `User-Agent`, `Cookie`, `Host`, `Content-Length`) are refused by the transport.
    public var headers: [String: String]
    /// Sent as `Authorization: Bearer <token>`.
    public var bearerToken: SecretBytes?
    /// The JSON body, if any.
    public var body: SecretBytes?

    public init(
        method: HTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        bearerToken: SecretBytes? = nil,
        body: SecretBytes? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.bearerToken = bearerToken
        self.body = body
    }
}

extension HTTPRequestModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "HTTPRequestModel(\(method.rawValue) \(url.host ?? "-"), body \(body?.count ?? 0) bytes)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}

/// A provider's answer.
///
/// ``body`` may hold values (a Key Vault secret, a Vercel variable): read the fields you need
/// with the secret JSON scanner, then call `body.wipe()`.
public struct HTTPResponseModel: Sendable {
    public let status: Int
    /// Header names lowercased.
    public let headers: [String: String]
    public let body: SecretBytes

    /// `headers` names are lowercased here; when two names differ only in case, the first in
    /// sorted order wins.
    public init(status: Int, headers: [String: String] = [:], body: SecretBytes = SecretBytes(count: 0)) {
        self.status = status
        var lowercased: [String: String] = [:]
        for name in headers.keys.sorted() {
            let key = name.lowercased()
            if lowercased[key] == nil {
                lowercased[key] = headers[name]
            }
        }
        self.headers = lowercased
        self.body = body
    }

    /// The value of the header `name` (any case).
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// 2xx.
    public var isSuccess: Bool {
        HTTPStatus.success.contains(status)
    }
}

extension HTTPResponseModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "HTTPResponseModel(\(status), body \(body.count) bytes)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}

/// Sends one HTTPS request (v0.8.0).
///
/// ``URLSessionTransport`` is the real implementation; tests and previews use
/// ``FakeHTTPTransport``. A transport returns every HTTP status as a response; it throws only
/// when no answer arrived or the request was refused before sending.
public protocol HTTPTransporting: Sendable {
    /// Sends `request` and returns the provider's answer.
    ///
    /// Throws ``DestinationError/disallowedHost`` for a URL outside the allowlist,
    /// ``DestinationError/network``, ``DestinationError/timeout``,
    /// ``DestinationError/cancelled`` and ``DestinationError/responseTooLarge``.
    func send(_ request: HTTPRequestModel) async throws(DestinationError) -> HTTPResponseModel
}
