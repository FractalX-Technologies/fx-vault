import Darwin
import Foundation
import VaultCore

/// The real ``HTTPTransporting``: one ephemeral `URLSession` (v0.8.0, tasks/todo.md R4,
/// docs/SECURITY-MODEL.md §7).
///
/// - No URL cache, no cookies, no credential storage; `Timeouts.destinationRequest` for each
///   request and for the whole transfer; TLS 1.2 or later.
/// - HTTPS to the allowlisted hosts only (``DestinationHostPolicy``), checked before sending and
///   on the final response URL. Redirects are never followed: the 3xx answer becomes
///   ``DestinationError/disallowedHost``.
/// - The body is sent from a private copy that is zeroed when Foundation releases it; the
///   answer is read into a ``SecretByteBuffer`` and stops at `Limits.maxDestinationResponseBytes`
///   (``DestinationError/responseTooLarge``). Buffers inside URLSession and the network stack
///   cannot be wiped.
/// - `User-Agent: FXVault`; `Authorization` only from ``HTTPRequestModel/bearerToken``.
/// - Nothing is logged here.
public final class URLSessionTransport: HTTPTransporting {
    private let session: URLSession
    private let maxResponseBytes: Int

    /// Capacity of the response buffer before the first byte arrives.
    private static let initialResponseCapacity = 4 * Limits.bytesPerKiB

    public init(maxResponseBytes: Int = Limits.maxDestinationResponseBytes) {
        self.maxResponseBytes = maxResponseBytes
        session = URLSession(configuration: Self.makeConfiguration(), delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }

    deinit {
        // A URLSession keeps its delegate until it is invalidated.
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: HTTPRequestModel) async throws(DestinationError) -> HTTPResponseModel {
        let urlRequest = try Self.makeURLRequest(request)
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw DestinationError.decoding
            }
            guard let finalURL = http.url, DestinationHostPolicy.isAllowed(finalURL) else {
                bytes.task.cancel()
                throw DestinationError.disallowedHost
            }
            if http.expectedContentLength > Int64(maxResponseBytes) {
                bytes.task.cancel()
                throw DestinationError.responseTooLarge
            }
            let buffer = SecretByteBuffer(capacity: Self.initialResponseCapacity)
            for try await byte in bytes {
                guard buffer.count < maxResponseBytes else {
                    bytes.task.cancel()
                    buffer.wipe()
                    throw DestinationError.responseTooLarge
                }
                buffer.append(byte)
            }
            return HTTPResponseModel(status: http.statusCode, headers: Self.headers(of: http), body: buffer.makeSecretBytes())
        } catch let error as DestinationError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network
        }
    }

    // MARK: - Policy pieces (tested without the network)

    /// The session configuration: ephemeral, no cache, cookies or credential storage, the
    /// request timeout for each request and the whole transfer, TLS 1.2+.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = Timeouts.destinationRequest.timeInterval
        configuration.timeoutIntervalForResource = Timeouts.destinationRequest.timeInterval
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    /// The `URLRequest` for `request`. Throws ``DestinationError/disallowedHost`` for a URL
    /// outside the allowlist, ``DestinationError/tokenMissing`` for a token that is not
    /// printable ASCII, and ``DestinationError/invalidRequest(code:)``
    /// (``DestinationError/LocalCode/invalidHeader``) for a reserved header or a header value
    /// with a line break.
    static func makeURLRequest(_ request: HTTPRequestModel) throws(DestinationError) -> URLRequest {
        guard DestinationHostPolicy.isAllowed(request.url) else { throw .disallowedHost }
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Timeouts.destinationRequest.timeInterval
        )
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            guard !HTTPHeader.reserved.contains(name.lowercased()), isSafeHeaderText(name), isSafeHeaderText(value) else {
                throw .invalidRequest(code: DestinationError.LocalCode.invalidHeader)
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue(DestinationConstants.userAgent, forHTTPHeaderField: HTTPHeader.userAgent)
        if let token = request.bearerToken {
            guard BearerToken.isUsable(token) else { throw .tokenMissing }
            let text = token.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
            urlRequest.setValue(HTTPHeader.bearerPrefix + text, forHTTPHeaderField: HTTPHeader.authorization)
        }
        if let body = request.body {
            urlRequest.httpBody = wipingData(copying: body)
        }
        return urlRequest
    }

    /// A `Data` over a private copy of `bytes` whose memory is zeroed and freed when Foundation
    /// releases the last reference (URLSession's own buffers are outside FX Vault's reach).
    static func wipingData(copying bytes: SecretBytes) -> Data {
        let count = bytes.count
        guard count > 0 else { return Data() }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: MemoryLayout<UInt8>.alignment)
        bytes.withUnsafeBytes { source in
            if let base = source.baseAddress {
                pointer.copyMemory(from: base, byteCount: count)
            }
        }
        return Data(bytesNoCopy: pointer, count: count, deallocator: .custom { memory, size in
            _ = memset_s(memory, size, 0, size)
            memory.deallocate()
        })
    }

    /// Maps a URLSession failure: no connection, DNS, lost connections and TLS failures are
    /// ``DestinationError/network``; a timeout is ``DestinationError/timeout``; a cancellation
    /// ``DestinationError/cancelled``; redirect and ATS refusals
    /// ``DestinationError/disallowedHost``; an oversized answer
    /// ``DestinationError/responseTooLarge``; an unreadable one ``DestinationError/decoding``.
    static func map(_ error: URLError) -> DestinationError {
        switch error.code {
        case .timedOut:
            .timeout
        case .cancelled, .userCancelledAuthentication:
            .cancelled
        case .httpTooManyRedirects, .redirectToNonExistentLocation, .appTransportSecurityRequiresSecureConnection,
             .unsupportedURL, .badURL:
            .disallowedHost
        case .dataLengthExceedsMaximum:
            .responseTooLarge
        case .cannotDecodeRawData, .cannotDecodeContentData, .cannotParseResponse:
            .decoding
        default:
            .network
        }
    }

    /// The response headers with lowercased names (``HTTPResponseModel`` lowercases too).
    static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers[name.lowercased()] = value
        }
        return headers
    }

    private static func isSafeHeaderText(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
    }
}

/// Refuses every redirect, so URLSession hands the 3xx answer back instead of following it.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
