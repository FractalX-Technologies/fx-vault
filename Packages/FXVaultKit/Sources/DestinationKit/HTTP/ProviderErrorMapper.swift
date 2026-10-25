import Foundation
import VaultCore

/// Turns a provider's non-2xx answer into a ``DestinationError`` (v0.8.0).
///
/// Only the provider's error code is read from the body, with the secret JSON scanner, and only
/// when it is a short identifier (``DestinationError/sanitizedCode(_:)``); messages are never
/// kept. The body is wiped afterwards.
enum ProviderErrorMapper {
    /// Key Vault's code for a name held by a soft-deleted secret.
    static let keyVaultDeletedButRecoverable = "ObjectIsDeletedButRecoverable"

    /// The error for `response` (any non-2xx status). Wipes `response.body`.
    static func error(for response: HTTPResponseModel, provider: DestinationProvider, now: Date) -> DestinationError {
        let codes = errorCodes(in: response.body, provider: provider)
        response.body.wipe()
        let code = codes.first
        let status = response.status
        switch status {
        case HTTPStatus.unauthorized:
            return .unauthorized
        case HTTPStatus.paymentRequired:
            return .forbidden
        case HTTPStatus.forbidden:
            return .forbidden
        case HTTPStatus.notFound, HTTPStatus.gone:
            return .notFound
        case HTTPStatus.conflict:
            return codes.contains(keyVaultDeletedButRecoverable) ? .deletedButRecoverable : .conflict(code: code)
        case HTTPStatus.payloadTooLarge:
            return .valueTooLarge
        case HTTPStatus.tooManyRequests:
            return .rateLimited(retryAfter: RetryAfter.duration(from: response.header(HTTPHeader.retryAfter), now: now))
        case HTTPStatus.redirection:
            return .disallowedHost
        case HTTPStatus.clientError:
            return .invalidRequest(code: code)
        default:
            return .server(status: status)
        }
    }

    /// The provider's error codes in the body, most specific first, sanitized:
    /// Key Vault: `error.innererror.code`, then `error.code`.
    static func errorCodes(in body: SecretBytes, provider: DestinationProvider) -> [String] {
        guard !body.isEmpty, let document = try? SecretJSONDocument(parsing: body) else { return [] }
        let candidates: [String?]
        switch provider {
        case .azureKeyVault:
            candidates = [document.string("error", "innererror", "code"), document.string("error", "code")]
        }
        return candidates.compactMap(DestinationError.sanitizedCode)
    }
}

/// `Retry-After` (RFC 9110 §10.2.3): delay-seconds or an HTTP-date.
enum RetryAfter {
    private static let httpDateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    private static let posixLocale = "en_US_POSIX"
    private static let gmt = "GMT"

    /// The wait `value` asks for, or nil when it is missing or unreadable. A date in the past is
    /// a zero wait.
    static func duration(from value: String?, now: Date) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int64(value) {
            return seconds >= 0 ? .seconds(seconds) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: posixLocale)
        formatter.timeZone = TimeZone(identifier: gmt)
        formatter.dateFormat = httpDateFormat
        guard let date = formatter.date(from: value) else { return nil }
        return .seconds(max(date.timeIntervalSince(now), 0))
    }
}
