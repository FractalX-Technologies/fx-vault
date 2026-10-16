import Foundation
import VaultCore

/// One Azure Key Vault's secrets over the data plane, api-version 7.4 (v0.8.0, tasks/todo.md R4,
/// R5).
///
/// - `list()`: `GET /secrets?api-version=7.4&maxresults=25`, then each `nextLink` (same host,
///   https only, else ``DestinationError/disallowedHost``).
/// - `readValue`: `GET /secrets/<name>?api-version=7.4`, `value` read with the scanner.
/// - `setValue`: `PUT /secrets/<name>?api-version=7.4` with `{"value": …}`. A name held by a
///   soft-deleted secret (409 `ObjectIsDeletedButRecoverable`) is recovered
///   (`POST /deletedsecrets/<name>/recover`), polled with `GET /secrets/<name>` until it is back
///   (every `Timeouts.verifyRetryInterval`, at most `Timeouts.verifyRetryWindow`), then written
///   again. A PUT creates a new version; the old version's content type and tags are not copied.
/// - `delete`: `DELETE /secrets/<name>?api-version=7.4`, a soft delete; FX Vault never purges.
struct AzureKeyVaultRemote: DestinationRemoting {
    let provider = DestinationProvider.azureKeyVault

    private static let apiVersionKey = "api-version"
    private static let maxResultsKey = "maxresults"
    private static let secretsSegment = "secrets"
    private static let deletedSecretsSegment = "deletedsecrets"
    private static let recoverSegment = "recover"
    private static let valueField = "value"
    private static let nextLinkField = "nextLink"
    private static let idField = "id"
    private static let attributesField = "attributes"
    private static let enabledField = "enabled"
    private static let updatedField = "updated"
    private static let managedField = "managed"
    /// Key Vault secret names: 1–127 letters, digits and dashes.
    private static let maxSecretNameLength = DestinationRules.maxKeyVaultNameLength

    private let host: String
    private let client: ProviderHTTPClient
    private let clock: any VaultClock

    init(vaultName: String, client: ProviderHTTPClient, clock: any VaultClock) {
        host = DestinationHostPolicy.keyVaultHost(vaultName: vaultName)
        self.client = client
        self.clock = clock
    }

    // MARK: - DestinationRemoting

    func list() async throws(DestinationError) -> [RemoteDestinationItemModel] {
        let firstPage = try url([Self.secretsSegment], extraQuery: [(Self.maxResultsKey, String(DestinationConstants.keyVaultPageSize))])
        var pageURL = firstPage
        var seenLinks: Set<String> = []
        var items: [RemoteDestinationItemModel] = []
        for _ in 0..<DestinationConstants.maxListPages {
            let response = try await client.send(.get, pageURL, retry: .idempotent)
            defer { response.body.wipe() }
            let document = try SecretJSONDocument(parsing: response.body)
            guard let entries = document.elements(.key(Self.valueField)) else { throw .decoding }
            for entry in entries {
                items.append(try Self.item(from: entry))
            }
            guard let nextLink = document.string(.key(Self.nextLinkField)), !nextLink.isEmpty else {
                return items
            }
            guard seenLinks.insert(nextLink).inserted else { throw .decoding }
            guard let next = URL(string: nextLink), DestinationHostPolicy.isSameAllowedHost(next, as: firstPage) else {
                throw .disallowedHost
            }
            pageURL = next
        }
        throw .responseTooLarge
    }

    func readValue(of item: RemoteDestinationItemModel) async throws(DestinationError) -> SecretBytes {
        try RemoteWriteCheck.requireReadable(item)
        let response = try await client.send(.get, try secretURL(item.remoteName), retry: .idempotent)
        defer { response.body.wipe() }
        guard let value = try SecretJSONDocument.secretField(Self.valueField, in: response.body) else { throw .decoding }
        return value
    }

    func setValue(
        _ value: SecretBytes,
        name: String,
        kind: ConfigKind,
        existing: RemoteDestinationItemModel?
    ) async throws(DestinationError) -> RemoteWriteResultModel {
        _ = try RemoteWriteCheck.validate(name: name, kind: kind, value: value, provider: provider)
        let remoteName = existing?.remoteName ?? DestinationRules.remoteName(for: name, provider: provider)
        let body = JSONBodyValue.members([Self.valueField: .secret(value)])
        do {
            return try await put(remoteName, body: body)
        } catch .deletedButRecoverable {
            try await recover(remoteName)
            return try await put(remoteName, body: body)
        }
    }

    func delete(_ item: RemoteDestinationItemModel) async throws(DestinationError) {
        let response = try await client.send(.delete, try secretURL(item.remoteName), retry: .idempotent)
        response.body.wipe()
    }

    // MARK: - Writing

    private func put(_ remoteName: String, body: JSONBodyValue) async throws(DestinationError) -> RemoteWriteResultModel {
        let response = try await client.send(.put, try secretURL(remoteName), body: body, retry: .idempotent)
        defer { response.body.wipe() }
        let document = try SecretJSONDocument(parsing: response.body)
        let updated = document.integer(.key(Self.attributesField), .key(Self.updatedField))
        return RemoteWriteResultModel(version: updated.map(String.init), remoteRef: nil)
    }

    /// Recovers the soft-deleted `remoteName` and waits until it can be read again (404 while
    /// the recovery runs). A 403 also counts as back: the secret exists, the account may only
    /// lack `get`. After the window the caller's PUT reports whatever Key Vault answers.
    private func recover(_ remoteName: String) async throws(DestinationError) {
        try validateSecretName(remoteName)
        let recoverURL = try url([Self.deletedSecretsSegment, remoteName, Self.recoverSegment])
        let recovered = try await client.send(.post, recoverURL, retry: .never)
        recovered.body.wipe()

        let probeURL = try secretURL(remoteName)
        let deadline = clock.uptime + Timeouts.verifyRetryWindow
        while true {
            do {
                let response = try await client.send(.get, probeURL, retry: .idempotent)
                response.body.wipe()
                return
            } catch .notFound {
                guard clock.uptime + Timeouts.verifyRetryInterval <= deadline else { return }
            } catch .forbidden {
                return
            }
            do {
                try await clock.sleep(for: Timeouts.verifyRetryInterval)
            } catch {
                throw .cancelled
            }
        }
    }

    // MARK: - Decoding

    /// A listed secret (`SecretItem`). The name is the path segment after `secrets` in `id`.
    static func item(from entry: SecretJSONDocument) throws(DestinationError) -> RemoteDestinationItemModel {
        guard let id = entry.string(.key(idField)), let remoteName = secretName(fromID: id) else { throw .decoding }
        let enabled = entry.bool(.key(attributesField), .key(enabledField)) ?? true
        let managed = entry.bool(.key(managedField)) ?? false
        let updated = entry.integer(.key(attributesField), .key(updatedField))
        let reason: DestinationUnusableReason?
        if managed {
            reason = .managed
        } else if !enabled {
            reason = .disabled
        } else {
            reason = DestinationRules.unusableReason(forRemoteName: remoteName, provider: .azureKeyVault)
                .map(DestinationUnusableReason.invalidName)
        }
        return RemoteDestinationItemModel(
            remoteName: remoteName,
            name: DestinationRules.localName(forRemoteName: remoteName, provider: .azureKeyVault),
            unusableReason: reason,
            kind: .secret,
            version: updated.map(String.init),
            isValueReadable: enabled,
            updatedAt: updated.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    /// `https://<vault>.vault.azure.net/secrets/<name>[/<version>]` → `<name>`.
    static func secretName(fromID id: String) -> String? {
        guard let url = URL(string: id) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let index = components.firstIndex(of: secretsSegment), components.indices.contains(index + 1) else {
            return nil
        }
        let name = components[index + 1]
        return name.isEmpty ? nil : name
    }

    // MARK: - URLs

    private func secretURL(_ remoteName: String) throws(DestinationError) -> URL {
        try validateSecretName(remoteName)
        return try url([Self.secretsSegment, remoteName])
    }

    private func url(_ segments: [String], extraQuery: [(String, String)] = []) throws(DestinationError) -> URL {
        let query = [(name: Self.apiVersionKey, value: DestinationConstants.keyVaultAPIVersion)]
            + extraQuery.map { (name: $0.0, value: $0.1) }
        return try ProviderURL.make(host: host, segments: segments, query: query)
    }

    /// 1–127 ASCII letters, digits and dashes (Azure's secret naming rules).
    private func validateSecretName(_ name: String) throws(DestinationError) {
        let scalars = name.unicodeScalars
        let isValid = (1...Self.maxSecretNameLength).contains(scalars.count) && scalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
        }
        guard isValid else { throw .invalidInput(.invalidName(.invalidCharacter)) }
    }
}
