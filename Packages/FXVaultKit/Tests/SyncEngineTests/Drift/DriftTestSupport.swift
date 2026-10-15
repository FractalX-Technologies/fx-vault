import Foundation
import GitHubKit
import SyncEngine
import VaultCore

/// Remote listings for drift tests, built through the same GitHubKit types the app decodes.
enum RemoteFx {
    static let monday = Date(timeIntervalSince1970: 1_791_000_000)
    static let tuesday = monday.addingTimeInterval(TimeInterval(Timeouts.secondsPerDay))

    static func secret(_ name: String, updatedAt: Date? = monday) -> GHSecretDTO {
        GHSecretDTO(name: name, updatedAt: updatedAt)
    }

    static func variable(_ name: String, value: String, updatedAt: Date? = monday) -> GHVariableListingModel {
        GHVariableListingModel(name: name, value: SecretBytes(utf8: value), updatedAt: updatedAt, createdAt: monday)
    }

    static func scope(secrets: [GHSecretDTO] = [], variables: [GHVariableListingModel] = []) -> RemoteScopeListingInputModel {
        RemoteScopeListingInputModel(secrets: secrets, variables: variables)
    }

    /// A B3 environment, decoded from GitHub's JSON shape.
    static func environmentDTO(_ name: String, id: Int64, policy: BranchPolicyKind = .all) throws -> GHEnvironmentDTO {
        let policyJSON: Any = switch policy {
        case .all: NSNull()
        case .protected: ["protected_branches": true, "custom_branch_policies": false]
        case .custom: ["protected_branches": false, "custom_branch_policies": true]
        }
        let object: [String: Any] = [
            "id": id,
            "name": name,
            "updated_at": "2026-10-01T10:00:00Z",
            "protection_rules": [],
            "deployment_branch_policy": policyJSON,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GHEnvironmentDTO.self, from: data)
    }

    static func environment(
        _ name: String,
        id: Int64,
        policy: BranchPolicyKind = .all,
        listing: RemoteScopeListingInputModel? = RemoteScopeListingInputModel(secrets: [], variables: [])
    ) throws -> RemoteEnvironmentInputModel {
        RemoteEnvironmentInputModel(environment: try environmentDTO(name, id: id, policy: policy), listing: listing)
    }

    static func snapshot(
        _ local: RepoSnapshotModel,
        repository: RemoteScopeListingInputModel? = RemoteScopeListingInputModel(secrets: [], variables: []),
        environments: [RemoteEnvironmentInputModel] = []
    ) -> RemoteSnapshotModel {
        RemoteSnapshotModel(local: local, repository: repository, environments: environments, fingerprint: Fx.fingerprint)
    }

    static func detect(
        _ local: RepoSnapshotModel,
        repository: RemoteScopeListingInputModel? = RemoteScopeListingInputModel(secrets: [], variables: []),
        environments: [RemoteEnvironmentInputModel] = [],
        suppression: DriftSuppressionModel = .none
    ) -> [DriftModel] {
        DriftDetector.detect(
            local: local,
            remote: snapshot(local, repository: repository, environments: environments),
            suppression: suppression
        )
    }
}
