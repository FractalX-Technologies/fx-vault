import Foundation
import VaultCore

/// JSON encoding and decoding of ``SharePackageModel`` (§9.3).
///
/// - Keys are sorted, dates are ISO-8601 UTC (`…Z`, whole seconds on output; fractional seconds
///   are accepted on input).
/// - `value` and `githubUpdatedAt` are written as explicit `null` when absent, so the manifest is
///   the same document with every value null. A partial environment's `deploymentBranchPolicy`
///   is an explicit `null` too (schema v2).
/// - Plaintext JSON is returned as ``SecretBytes``; intermediate `Data` buffers are wiped.
public enum SharePackageCoder {
    /// Encodes `package` to UTF-8 JSON. Throws `.payloadTooLarge` above
    /// ``Limits/maxSharePayloadBytes`` and `.invalidPackage(.valueNotUTF8)` for binary values.
    public static func encode(_ package: SharePackageModel) throws(ShareError) -> SecretBytes {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ShareDateFormat.string(from: date))
        }
        var data: Data
        do {
            data = try encoder.encode(package)
        } catch let error as ShareCodingError {
            throw .invalidPackage(error.violation)
        } catch {
            throw .encryptionFailed
        }
        defer { data.wipe() }
        guard data.count <= Limits.maxSharePayloadBytes else { throw .payloadTooLarge }
        return SecretBytes(data)
    }

    /// Decodes UTF-8 JSON into a package. Every decoding failure, including size, is
    /// `ShareError.invalidFile` (§9.1 step 10). The result is not validated yet: call
    /// ``SharePackageValidator/validate(_:mode:)``.
    public static func decode(_ json: SecretBytes) throws(ShareError) -> SharePackageModel {
        guard json.count <= Limits.maxSharePayloadBytes else { throw .invalidFile }
        var data = json.withUnsafeBytes { Data($0) }
        defer { data.wipe() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ShareDateFormat.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 date"
                )
            }
            return date
        }
        do {
            return try decoder.decode(SharePackageModel.self, from: data)
        } catch {
            throw .invalidFile
        }
    }
}

/// ISO-8601 UTC dates for the share schema.
enum ShareDateFormat {
    private static let wholeSeconds = Date.ISO8601FormatStyle()
    private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func string(from date: Date) -> String {
        wholeSeconds.format(date)
    }

    static func date(from text: String) -> Date? {
        if let date = try? wholeSeconds.parse(text) { return date }
        return try? fractionalSeconds.parse(text)
    }
}

/// Encoding failures that map to a package violation.
struct ShareCodingError: Error {
    let violation: SharePackageViolation
}

// MARK: - Codable

extension SharePackageModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case schema
        case schemaVersion
        case packageID = "packageId"
        case createdAt
        case producer
        case sender
        case scope
        case repository
        case folder
    }

    /// A folder package (v0.7.0) carries `folder` instead of `repository`.
    private enum FolderCodingKeys: String, CodingKey {
        case name
        case secrets
        case variables
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        packageID = try container.decode(SharePackageID.self, forKey: .packageID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        producer = try container.decode(ShareProducerModel.self, forKey: .producer)
        sender = try container.decode(ShareSenderModel.self, forKey: .sender)
        scope = try container.decode(ShareScope.self, forKey: .scope)
        guard scope == .folder else {
            guard !container.contains(.folder) else {
                throw DecodingError.dataCorruptedError(forKey: .folder, in: container, debugDescription: "Unexpected folder")
            }
            repository = try container.decode(ShareRepositoryModel.self, forKey: .repository)
            folder = nil
            return
        }
        guard !container.contains(.repository) else {
            throw DecodingError.dataCorruptedError(forKey: .repository, in: container, debugDescription: "Unexpected repository")
        }
        let content = try container.nestedContainer(keyedBy: FolderCodingKeys.self, forKey: .folder)
        folder = ShareFolderModel(name: try content.decode(String.self, forKey: .name))
        repository = ShareFolderModel.container(
            secrets: try content.decodeIfPresent([ShareItemModel].self, forKey: .secrets) ?? [],
            variables: try content.decodeIfPresent([ShareItemModel].self, forKey: .variables) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(packageID, forKey: .packageID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(producer, forKey: .producer)
        try container.encode(sender, forKey: .sender)
        try container.encode(scope, forKey: .scope)
        guard scope == .folder, let folder else {
            try container.encode(repository, forKey: .repository)
            return
        }
        var content = container.nestedContainer(keyedBy: FolderCodingKeys.self, forKey: .folder)
        try content.encode(folder.name, forKey: .name)
        try content.encode(repository.secrets, forKey: .secrets)
        try content.encode(repository.variables, forKey: .variables)
    }
}

extension ShareRepositoryModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case host
        case owner
        case name
        case githubRepoID = "githubRepoId"
        case secrets
        case variables
        case environments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        owner = try container.decode(String.self, forKey: .owner)
        name = try container.decode(String.self, forKey: .name)
        githubRepoID = try container.decodeIfPresent(String.self, forKey: .githubRepoID)
        secrets = try container.decodeIfPresent([ShareItemModel].self, forKey: .secrets) ?? []
        variables = try container.decodeIfPresent([ShareItemModel].self, forKey: .variables) ?? []
        environments = try container.decodeIfPresent(
            [ShareEnvironmentModel].self,
            forKey: .environments
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(owner, forKey: .owner)
        try container.encode(name, forKey: .name)
        try container.encode(githubRepoID, forKey: .githubRepoID)
        try container.encode(secrets, forKey: .secrets)
        try container.encode(variables, forKey: .variables)
        try container.encode(environments, forKey: .environments)
    }
}

extension ShareItemModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case value
        case valueState
        case githubUpdatedAt
        case syncState
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ShareEntryID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decodeIfPresent(String.self, forKey: .value).map {
            SecretBytes(utf8: $0)
        }
        valueState = try container.decode(ConfigValueState.self, forKey: .valueState)
        githubUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .githubUpdatedAt)
        syncState = try container.decode(ShareSyncState.self, forKey: .syncState)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        if let value {
            guard let text = value.utf8String() else {
                throw ShareCodingError(violation: .valueNotUTF8)
            }
            try container.encode(text, forKey: .value)
        } else {
            try container.encodeNil(forKey: .value)
        }
        try container.encode(valueState, forKey: .valueState)
        try container.encode(githubUpdatedAt, forKey: .githubUpdatedAt)
        try container.encode(syncState, forKey: .syncState)
    }
}

extension ShareEnvironmentModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case deploymentBranchPolicy
        case secrets
        case variables
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ShareEntryID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Null (schema v2, partial environment) decodes as nil; the validator rejects a missing
        // policy wherever one is required (schema v1, `environment` scope, no items).
        deploymentBranchPolicy = try container.decodeIfPresent(
            ShareBranchPolicyModel.self,
            forKey: .deploymentBranchPolicy
        )
        secrets = try container.decodeIfPresent([ShareItemModel].self, forKey: .secrets) ?? []
        variables = try container.decodeIfPresent([ShareItemModel].self, forKey: .variables) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(deploymentBranchPolicy, forKey: .deploymentBranchPolicy)
        try container.encode(secrets, forKey: .secrets)
        try container.encode(variables, forKey: .variables)
    }
}
