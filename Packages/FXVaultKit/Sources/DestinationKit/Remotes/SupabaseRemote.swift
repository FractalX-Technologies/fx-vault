import Foundation
import VaultCore

/// One Supabase project's Edge Function secrets through the Management API (v0.8.0,
/// `https://api.supabase.com/v1`, a personal access token).
///
/// - `list()`: `GET /v1/projects/<ref>/secrets` → `[{"name", "value", "updated_at"?}]`, where
///   `value` is a digest of the secret (an opaque marker, lowercased), never the secret.
/// - `readValue`: refused (``DestinationError/LocalCode/writeOnly``): the API returns no values.
/// - `setValue`: `POST /v1/projects/<ref>/secrets` with `[{"name", "value"}]` (an upsert, so it
///   is retried like a PUT). The result has no version: re-list to read the new digest.
/// - `delete`: `DELETE /v1/projects/<ref>/secrets` with `["NAME"]`.
///
/// Names starting with `SUPABASE_` are Supabase's own and are listed as
/// ``DestinationUnusableReason/system``.
struct SupabaseRemote: DestinationRemoting {
    let provider = DestinationProvider.supabase

    static let apiVersionSegment = "v1"
    static let projectsSegment = "projects"
    static let secretsSegment = "secrets"
    private static let nameField = "name"
    private static let valueField = "value"
    private static let updatedAtField = "updated_at"

    private let projectRef: String
    private let client: ProviderHTTPClient

    init(projectRef: String, client: ProviderHTTPClient) {
        self.projectRef = projectRef
        self.client = client
    }

    func list() async throws(DestinationError) -> [RemoteDestinationItemModel] {
        let response = try await client.send(.get, try secretsURL(), retry: .idempotent)
        defer { response.body.wipe() }
        let document = try SecretJSONDocument(parsing: response.body)
        guard let entries = document.elements() else { throw .decoding }
        var items: [RemoteDestinationItemModel] = []
        for entry in entries {
            items.append(try Self.item(from: entry))
        }
        return items
    }

    func readValue(of item: RemoteDestinationItemModel) async throws(DestinationError) -> SecretBytes {
        throw .invalidRequest(code: DestinationError.LocalCode.writeOnly)
    }

    func setValue(
        _ value: SecretBytes,
        name: String,
        kind: ConfigKind,
        existing: RemoteDestinationItemModel?
    ) async throws(DestinationError) -> RemoteWriteResultModel {
        _ = try RemoteWriteCheck.validate(name: name, kind: kind, value: value, provider: provider)
        let body = JSONBodyValue.array([.members([Self.nameField: .string(name), Self.valueField: .secret(value)])])
        let response = try await client.send(.post, try secretsURL(), body: body, retry: .idempotent)
        response.body.wipe()
        return RemoteWriteResultModel(version: nil, remoteRef: nil)
    }

    func delete(_ item: RemoteDestinationItemModel) async throws(DestinationError) {
        let response = try await client.send(.delete, try secretsURL(), body: .strings([item.remoteName]), retry: .idempotent)
        response.body.wipe()
    }

    // MARK: - Decoding

    static func item(from entry: SecretJSONDocument) throws(DestinationError) -> RemoteDestinationItemModel {
        guard let remoteName = entry.string(.key(nameField)), !remoteName.isEmpty else { throw .decoding }
        let digest = entry.string(.key(valueField)).map { $0.lowercased() }
        let reason: DestinationUnusableReason?
        if remoteName.hasPrefix(DestinationRules.supabaseReservedPrefix) {
            reason = .system
        } else {
            reason = DestinationRules.unusableReason(forRemoteName: remoteName, provider: .supabase)
                .map(DestinationUnusableReason.invalidName)
        }
        return RemoteDestinationItemModel(
            remoteName: remoteName,
            name: DestinationRules.localName(forRemoteName: remoteName, provider: .supabase),
            unusableReason: reason,
            kind: .secret,
            version: digest,
            digest: digest,
            isValueReadable: false,
            updatedAt: entry.string(.key(updatedAtField)).flatMap(ProviderDate.iso8601)
        )
    }

    private func secretsURL() throws(DestinationError) -> URL {
        try ProviderURL.make(
            host: DestinationConstants.supabaseHost,
            segments: [Self.apiVersionSegment, Self.projectsSegment, projectRef, Self.secretsSegment]
        )
    }
}

/// Timestamps in provider answers.
enum ProviderDate {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()
    private static let millisecondsPerSecond: TimeInterval = 1000

    /// An ISO 8601 date-time with or without fractional seconds, or nil.
    static func iso8601(_ text: String) -> Date? {
        (try? withFraction.parse(text)) ?? (try? withoutFraction.parse(text))
    }

    /// Unix milliseconds (Vercel).
    static func milliseconds(_ value: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value) / millisecondsPerSecond)
    }
}
