import Foundation
import VaultCore

/// JSON encoding and decoding of ``ShareBundleModel`` (schema 4, v0.9.0), with the conventions of
/// ``SharePackageCoder``: sorted keys, ISO-8601 UTC dates, explicit `null` for absent values and
/// optional fields, plaintext returned as ``SecretBytes`` and intermediate buffers wiped.
public enum ShareBundleCoder {
    /// Encodes `bundle` to UTF-8 JSON. Throws `.payloadTooLarge` above
    /// ``Limits/maxSharePayloadBytes`` and `.invalidPackage(.valueNotUTF8)` for binary values.
    public static func encode(_ bundle: ShareBundleModel) throws(ShareError) -> SecretBytes {
        var data: Data
        do {
            data = try ShareJSON.encoder().encode(bundle)
        } catch let error as ShareCodingError {
            throw .invalidPackage(error.violation)
        } catch {
            throw .encryptionFailed
        }
        defer { data.wipe() }
        guard data.count <= Limits.maxSharePayloadBytes else { throw .payloadTooLarge }
        return SecretBytes(data)
    }

    /// Decodes UTF-8 JSON into a bundle. Every decoding failure, including size and a `scope`
    /// other than `bundle`, is `ShareError.invalidFile`. Not validated yet: call
    /// ``ShareBundleValidator/validate(_:mode:)``.
    public static func decode(_ json: SecretBytes) throws(ShareError) -> ShareBundleModel {
        guard json.count <= Limits.maxSharePayloadBytes else { throw .invalidFile }
        var data = json.withUnsafeBytes { Data($0) }
        defer { data.wipe() }
        do {
            return try ShareJSON.decoder().decode(ShareBundleModel.self, from: data)
        } catch {
            throw .invalidFile
        }
    }
}

/// A decoded share document: a schema 1–3 package or a schema 4 bundle (v0.9.0).
public enum ShareDocumentModel: Sendable, Equatable {
    case package(SharePackageModel)
    case bundle(ShareBundleModel)

    public var packageID: SharePackageID {
        switch self {
        case .package(let package): package.packageID
        case .bundle(let bundle): bundle.packageID
        }
    }

    /// Zeroes every value buffer in place.
    public func wipeValues() {
        switch self {
        case .package(let package): package.wipeValues()
        case .bundle(let bundle): bundle.wipeValues()
        }
    }
}

/// Reads any share document: `schemaVersion` 4 is a bundle, anything else goes to
/// ``SharePackageCoder`` (whose validator rejects versions it does not know).
public enum ShareDocumentCoder {
    /// Decodes `json` without validating it. Every decoding failure is `.invalidFile`.
    public static func decode(_ json: SecretBytes) throws(ShareError) -> ShareDocumentModel {
        guard json.count <= Limits.maxSharePayloadBytes else { throw .invalidFile }
        let version: Int
        do {
            var data = json.withUnsafeBytes { Data($0) }
            defer { data.wipe() }
            version = try JSONDecoder().decode(VersionProbe.self, from: data).schemaVersion
        } catch {
            throw .invalidFile
        }
        if version == ShareBundleModel.schemaVersion {
            return .bundle(try ShareBundleCoder.decode(json))
        }
        return .package(try SharePackageCoder.decode(json))
    }

    /// Decodes and validates `json` (``SharePackageValidator`` or ``ShareBundleValidator``).
    /// The values are wiped when validation fails.
    public static func open(_ json: SecretBytes, mode: SharePackageValidator.Mode = .payload) throws(ShareError) -> ShareDocumentModel {
        let document = try decode(json)
        do {
            switch document {
            case .package(let package): try SharePackageValidator.validate(package, mode: mode)
            case .bundle(let bundle): try ShareBundleValidator.validate(bundle, mode: mode)
            }
        } catch {
            document.wipeValues()
            throw error
        }
        return document
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }
}

/// The JSON coders of the share schema.
enum ShareJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ShareDateFormat.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ShareDateFormat.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 date")
            }
            return date
        }
        return decoder
    }
}

// MARK: - Codable

extension ShareBundleModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case schema
        case schemaVersion
        case packageID = "packageId"
        case createdAt
        case expiresAt
        case producer
        case sender
        case scope
        case stages
        case repositories
        case folders
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard try container.decode(String.self, forKey: .scope) == Self.scopeIdentifier else {
            throw DecodingError.dataCorruptedError(forKey: .scope, in: container, debugDescription: "Expected a bundle")
        }
        packageID = try container.decode(SharePackageID.self, forKey: .packageID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        producer = try container.decode(ShareProducerModel.self, forKey: .producer)
        sender = try container.decode(ShareSenderModel.self, forKey: .sender)
        stages = try container.decodeIfPresent([String].self, forKey: .stages) ?? []
        repositories = try container.decodeIfPresent([ShareBundleRepositoryModel].self, forKey: .repositories) ?? []
        folders = try container.decodeIfPresent([ShareBundleFolderModel].self, forKey: .folders) ?? []
        if repositories.contains(where: { !$0.retiredDestinations.isEmpty }) {
            dropLoneLinkTokens()
        }
    }

    /// A dropped destination can leave its linked copy alone with its token, which the validator
    /// refuses. Only after a drop: a lone token in any other file still fails validation.
    private mutating func dropLoneLinkTokens() {
        let lone = Set(linkGroups.filter { $0.value.count < 2 }.keys)
        guard !lone.isEmpty else { return }
        let unlink: (ShareItemModel) -> ShareItemModel = { item in
            guard let token = item.linkToken, lone.contains(token) else { return item }
            var copy = item
            copy.linkToken = nil
            return copy
        }
        repositories = repositories.map { $0.mapItems(unlink) }
        folders = folders.map { $0.mapItems(unlink) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(packageID, forKey: .packageID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(producer, forKey: .producer)
        try container.encode(sender, forKey: .sender)
        try container.encode(Self.scopeIdentifier, forKey: .scope)
        try container.encode(stages, forKey: .stages)
        try container.encode(repositories, forKey: .repositories)
        try container.encode(folders, forKey: .folders)
    }
}

/// A repository entry is the schema 2 `repository` object plus `destinations`.
extension ShareBundleRepositoryModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case destinations
    }

    public init(from decoder: any Decoder) throws {
        repository = try ShareRepositoryModel(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decodeIfPresent([ShareDecodedDestination].self, forKey: .destinations) ?? []
        destinations = decoded.compactMap(\.destination)
        retiredDestinations = decoded.compactMap(\.retiredLabel)
    }

    public func encode(to encoder: any Encoder) throws {
        try repository.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(destinations, forKey: .destinations)
    }
}

extension ShareDestinationModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case stage
        case target
        case secrets
        case variables
    }

    /// Decodes a destination whose target is already known (``ShareDecodedDestination`` reads it).
    init(from decoder: any Decoder, target: DestinationTargetModel) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ShareEntryID.self, forKey: .id)
        stage = try container.decodeIfPresent(String.self, forKey: .stage)
        self.target = target
        secrets = try container.decodeIfPresent([ShareItemModel].self, forKey: .secrets) ?? []
        variables = try container.decodeIfPresent([ShareItemModel].self, forKey: .variables) ?? []
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wire = try container.decode(ShareDestinationTargetWire.self, forKey: .target)
        guard let target = wire.target else {
            throw DecodingError.dataCorruptedError(forKey: .target, in: container, debugDescription: "Retired provider")
        }
        try self.init(from: decoder, target: target)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(stage, forKey: .stage)
        try container.encode(ShareDestinationTargetWire(target), forKey: .target)
        try container.encode(secrets, forKey: .secrets)
        try container.encode(variables, forKey: .variables)
    }
}

/// One `destinations` entry: a Key Vault destination, or the label of a Supabase or Vercel one
/// that a 0.9 file carried (dropped with its items; `publicNames` is ignored the same way).
private struct ShareDecodedDestination: Decodable {
    private enum CodingKeys: String, CodingKey {
        case target
    }

    let destination: ShareDestinationModel?
    let retiredLabel: String?

    init(from decoder: any Decoder) throws {
        let wire = try decoder.container(keyedBy: CodingKeys.self).decode(ShareDestinationTargetWire.self, forKey: .target)
        if let target = wire.target {
            destination = try ShareDestinationModel(from: decoder, target: target)
            retiredLabel = nil
        } else {
            destination = nil
            retiredLabel = wire.retiredLabel
        }
    }
}

extension ShareBundleFolderModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case secrets
        case variables
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ShareEntryID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        secrets = try container.decodeIfPresent([ShareItemModel].self, forKey: .secrets) ?? []
        variables = try container.decodeIfPresent([ShareItemModel].self, forKey: .variables) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(secrets, forKey: .secrets)
        try container.encode(variables, forKey: .variables)
    }
}

/// The wire form of a destination target: `provider` and that provider's identifiers, absent
/// optionals as explicit `null`. 1.0 writes `azureKeyVault` only; `supabase` and `vercel` (0.9)
/// decode to a nil ``target`` and a ``retiredLabel``.
struct ShareDestinationTargetWire: Codable {
    enum Provider: String, Codable {
        case azureKeyVault
        case supabase
        case vercel
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case vaultName
        case tenantID = "tenantId"
        case projectRef
        case projectName
        case environment
    }

    let target: DestinationTargetModel?
    /// How the preview names a retired destination, as 0.9 did: `Supabase <ref>`,
    /// `Vercel <project> (<environment>)`.
    let retiredLabel: String?

    init(_ target: DestinationTargetModel) {
        self.target = target
        retiredLabel = nil
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Provider.self, forKey: .provider) {
        case .azureKeyVault:
            target = .azureKeyVault(
                vaultName: try container.decode(String.self, forKey: .vaultName),
                tenantID: try container.decodeIfPresent(String.self, forKey: .tenantID)
            )
            retiredLabel = nil
        case .supabase:
            target = nil
            retiredLabel = "Supabase \(try container.decode(String.self, forKey: .projectRef))"
        case .vercel:
            target = nil
            let project = try container.decode(String.self, forKey: .projectName)
            let environment = try container.decode(String.self, forKey: .environment)
            retiredLabel = "Vercel \(project) (\(environment))"
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch target {
        case .azureKeyVault(let vaultName, let tenantID):
            try container.encode(Provider.azureKeyVault, forKey: .provider)
            try container.encode(vaultName, forKey: .vaultName)
            try container.encode(tenantID, forKey: .tenantID)
        case nil:
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Retired provider"))
        }
    }
}
