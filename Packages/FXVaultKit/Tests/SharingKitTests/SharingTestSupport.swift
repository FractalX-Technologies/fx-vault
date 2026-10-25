import CryptoKit
import Foundation
import os
import Testing
import VaultCore
@testable import SharingKit

// MARK: - Hex and fixtures

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

enum Fixtures {
    static func url(_ path: String) throws -> URL {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return root.appendingPathComponent(path)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }
}

/// A known-answer document: `inputs` (hex text or numbers) and `outputs` (hex), as the Python
/// generators under Fixtures/kat write them.
struct KATDocument: Decodable {
    let inputs: [String: Inputs]
    let outputs: [String: String]

    enum Inputs: Decodable {
        case text(String)
        case number(Int64)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }
    }

    enum KATError: Error {
        case wrongType
    }

    static func load(_ name: String) throws -> KATDocument {
        try JSONDecoder().decode(KATDocument.self, from: Fixtures.data(name))
    }

    func input(_ key: String) throws -> String {
        guard case .text(let text) = try #require(inputs[key]) else { throw KATError.wrongType }
        return text
    }

    func number(_ key: String) throws -> Int64 {
        guard case .number(let number) = try #require(inputs[key]) else { throw KATError.wrongType }
        return number
    }

    func bytes(_ key: String) throws -> Data {
        try #require(Data(hex: try input(key)))
    }

    func output(_ key: String) throws -> String {
        try #require(outputs[key])
    }

    func outputBytes(_ key: String) throws -> Data {
        try #require(Data(hex: try output(key)))
    }
}

// MARK: - Deterministic randomness

/// SplitMix64, for reproducible "random" draws in tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

// MARK: - Key derivation fakes

/// Returns SHA-256(passphrase ‖ salt ‖ t ‖ m): deterministic, passphrase-dependent, instant.
struct FakeKeyDeriver: KeyDeriving {
    func deriveKey(passphrase: SecretBytes, parameters: KeyDerivationParametersModel) async throws -> SecretBytes {
        var hasher = SHA256()
        passphrase.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        hasher.update(data: parameters.salt)
        hasher.update(data: Data("\(parameters.opsLimit)/\(parameters.memLimitKiB)".utf8))
        return SecretBytes(copying: Array(hasher.finalize()))
    }
}

/// Always returns the same key (the KAT key 0x42 × 32).
struct FixedKeyDeriver: KeyDeriving {
    let key: Data

    func deriveKey(passphrase: SecretBytes, parameters: KeyDerivationParametersModel) async throws -> SecretBytes {
        SecretBytes(key)
    }
}

/// Counts calls; proves bounds are checked before the KDF.
final class SpyKeyDeriver: KeyDeriving {
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    var callCount: Int {
        calls.withLock { $0 }
    }

    func deriveKey(passphrase: SecretBytes, parameters: KeyDerivationParametersModel) async throws -> SecretBytes {
        calls.withLock { $0 += 1 }
        return try await FakeKeyDeriver().deriveKey(passphrase: passphrase, parameters: parameters)
    }
}

/// Throws CancellationError.
struct CancellingKeyDeriver: KeyDeriving {
    func deriveKey(passphrase: SecretBytes, parameters: KeyDerivationParametersModel) async throws -> SecretBytes {
        throw CancellationError()
    }
}

// MARK: - Package builders

enum PackageFactory {
    static let createdAt = Date(timeIntervalSince1970: 1_790_000_000)
    static let owner = "octo-org"
    static let repository = "service"
    static let githubRepoID = "R_kgDOAbCdEf"

    static func item(
        _ name: String,
        value: String? = "value-\(UUID().uuidString)",
        syncState: ShareSyncState = .synced,
        githubUpdatedAt: Date? = Date(timeIntervalSince1970: 1_789_000_000)
    ) -> ShareItemModel {
        ShareItemModel(
            name: name,
            value: value.map { SecretBytes(utf8: $0) },
            valueState: value == nil ? .missing : .present,
            githubUpdatedAt: githubUpdatedAt,
            syncState: syncState
        )
    }

    static func environment(
        _ name: String,
        policy: ShareBranchPolicyModel = ShareBranchPolicyModel(type: .all),
        secrets: [ShareItemModel] = [],
        variables: [ShareItemModel] = []
    ) -> ShareEnvironmentModel {
        ShareEnvironmentModel(name: name, deploymentBranchPolicy: policy, secrets: secrets, variables: variables)
    }

    /// A partial environment (schema v2): selected items only, no branch policy.
    static func partialEnvironment(
        _ name: String,
        secrets: [ShareItemModel] = [],
        variables: [ShareItemModel] = []
    ) -> ShareEnvironmentModel {
        ShareEnvironmentModel(name: name, deploymentBranchPolicy: nil, secrets: secrets, variables: variables)
    }

    static func package(
        scope: ShareScope = .repository,
        secrets: [ShareItemModel] = [],
        variables: [ShareItemModel] = [],
        environments: [ShareEnvironmentModel] = [],
        githubRepoID: String? = githubRepoID,
        createdAt: Date = createdAt,
        packageID: SharePackageID = SharePackageID()
    ) -> SharePackageModel {
        SharePackageModel(
            packageID: packageID,
            createdAt: createdAt,
            producer: ShareProducerModel(version: "1.0.0"),
            sender: ShareSenderModel(displayName: "Sam"),
            scope: scope,
            repository: ShareRepositoryModel(
                owner: owner,
                name: repository,
                githubRepoID: githubRepoID,
                secrets: secrets,
                variables: variables,
                environments: environments
            )
        )
    }

    /// A repository-scope package with repo-level items and one environment.
    static func sample() -> SharePackageModel {
        package(
            secrets: [item("API_KEY"), item("MISSING_SECRET", value: nil)],
            variables: [item("REGION", value: "eu-west-1")],
            environments: [
                environment(
                    "Producción",
                    policy: ShareBranchPolicyModel(type: .custom, patterns: [
                        ShareBranchPatternModel(name: "main", type: .branch),
                        ShareBranchPatternModel(name: "v*", type: .tag),
                    ]),
                    secrets: [item("DB_PASSWORD")],
                    variables: [item("LOG_LEVEL", value: "info")]
                ),
            ]
        )
    }
}
