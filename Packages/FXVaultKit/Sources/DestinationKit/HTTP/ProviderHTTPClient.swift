import Foundation
import os
import VaultCore

/// How a provider request is authorized.
enum ProviderCredential: Sendable {
    /// An `az` access token for Key Vault, asked for on every attempt. A 401 invalidates it and
    /// the request is sent once more with a fresh one.
    case azure(any AccessTokenProviding, tenantID: String?)
}

/// Whether a request may be sent again after a transient failure.
enum RequestRetry: Sendable {
    /// GET, PUT and DELETE: 429 is retried after `Retry-After` (or
    /// `Timeouts.destinationRateLimitBackoff`), up to `Limits.rateLimitRetries` times; 5xx and
    /// network errors up to `Limits.idempotentRetries` times, after
    /// `Timeouts.idempotentRetryBackoff` × attempt.
    case idempotent
    /// Sent once (Key Vault recover), apart from the Key Vault 401
    /// refresh, which a request that was refused cannot have applied.
    case never
}

/// Sends provider requests with the retry policy, authorization and error mapping (v0.8.0).
///
/// Bodies are encoded once and wiped after the last attempt; every attempt gets a fresh token
/// copy, wiped once the attempt ends. Sleeps run on the injected clock.
struct ProviderHTTPClient: Sendable {
    let provider: DestinationProvider
    let transport: any HTTPTransporting
    let clock: any VaultClock
    let credential: ProviderCredential

    /// Sends `method url` with `body` and returns the 2xx answer; the caller reads, then wipes,
    /// its body. Any other status throws its ``DestinationError`` (``ProviderErrorMapper``).
    func send(
        _ method: HTTPMethod,
        _ url: URL,
        body: JSONBodyValue? = nil,
        retry: RequestRetry
    ) async throws(DestinationError) -> HTTPResponseModel {
        let encodedBody: SecretBytes?
        if let body {
            encodedBody = try JSONBodyWriter.encode(body)
        } else {
            encodedBody = nil
        }
        defer { encodedBody?.wipe() }
        var headers = [HTTPHeader.accept: DestinationConstants.jsonMediaType]
        if encodedBody != nil {
            headers[HTTPHeader.contentType] = DestinationConstants.jsonMediaType
        }

        var transientRetries = 0
        var rateLimitRetries = 0
        var refreshedToken = false
        while true {
            guard !Task.isCancelled else { throw .cancelled }
            let token = try await bearerToken()
            let request = HTTPRequestModel(method: method, url: url, headers: headers, bearerToken: token, body: encodedBody)
            let outcome: Result<HTTPResponseModel, DestinationError>
            do {
                outcome = .success(try await transport.send(request))
            } catch {
                outcome = .failure(error)
            }
            token.wipe()

            let failure: DestinationError
            switch outcome {
            case .success(let response) where response.isSuccess:
                log(method, status: response.status, error: nil)
                return response
            case .success(let response):
                failure = ProviderErrorMapper.error(for: response, provider: provider, now: clock.now)
                log(method, status: response.status, error: failure)
            case .failure(let error):
                failure = error
                log(method, status: nil, error: error)
            }

            switch failure {
            case .unauthorized where !refreshedToken:
                guard case .azure(let tokens, let tenantID) = credential else { throw failure }
                await tokens.invalidate(tenantID: tenantID)
                refreshedToken = true
            case .rateLimited(let retryAfter) where retry == .idempotent && rateLimitRetries < Limits.rateLimitRetries:
                let wait = retryAfter ?? Timeouts.destinationRateLimitBackoff
                guard wait <= Timeouts.destinationMaxRetryAfter else { throw failure }
                rateLimitRetries += 1
                try await sleep(wait)
            case .server, .network, .timeout:
                guard retry == .idempotent, transientRetries < Limits.idempotentRetries else { throw failure }
                transientRetries += 1
                try await sleep(Timeouts.idempotentRetryBackoff * transientRetries)
            default:
                throw failure
            }
        }
    }

    /// A copy of the token for one attempt.
    private func bearerToken() async throws(DestinationError) -> SecretBytes {
        switch credential {
        case .azure(let tokens, let tenantID):
            return try await tokens.token(tenantID: tenantID)
        }
    }

    private func sleep(_ duration: Duration) async throws(DestinationError) {
        do {
            try await clock.sleep(for: duration)
        } catch {
            throw .cancelled
        }
    }

    private func log(_ method: HTTPMethod, status: Int?, error: DestinationError?) {
        let provider = provider.rawValue
        let method = method.rawValue
        let status = status.map(String.init) ?? "-"
        let code = error?.logCode ?? "ok"
        DestinationLog.http.debug(
            "\(provider, privacy: .public) \(method, privacy: .public) → \(status, privacy: .public) \(code, privacy: .public)"
        )
    }
}

/// Checks on a bearer token before it becomes the `Authorization` header.
enum BearerToken {
    private static let firstPrintable: UInt8 = 0x21
    private static let lastPrintable: UInt8 = 0x7E

    /// Non-empty printable ASCII without spaces, so it can never inject a header.
    static func isUsable(_ token: SecretBytes) -> Bool {
        token.withUnsafeBytes { bytes in
            !bytes.isEmpty && bytes.allSatisfy { (firstPrintable...lastPrintable).contains($0) }
        }
    }
}
