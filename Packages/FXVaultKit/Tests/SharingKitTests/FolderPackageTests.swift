import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Folder packages (v0.7.0, schema v3, tasks/todo.md F7): the wire form (`folder` instead of
/// `repository`), the validator rules and retargeting at a repository for "Import Into…".
@Suite("Folder packages")
struct FolderPackageTests {
    static func folder(
        name: String = "Mobile App",
        secrets: [ShareItemModel] = [PackageFactory.item("API_KEY", syncState: .pending, githubUpdatedAt: nil)],
        variables: [ShareItemModel] = [PackageFactory.item("API_URL", value: "https://api.example.invalid", syncState: .pending, githubUpdatedAt: nil)]
    ) -> SharePackageModel {
        .folder(
            named: name,
            secrets: secrets,
            variables: variables,
            createdAt: PackageFactory.createdAt,
            producer: ShareProducerModel(version: "0.7.0"),
            sender: ShareSenderModel(displayName: "Sam")
        )
    }

    // MARK: - Wire form

    @Test func aFolderTravelsAsAFolderObjectAtSchemaThree() throws {
        let package = Self.folder()
        defer { package.wipeValues() }
        #expect(package.schemaVersion == SharePackageModel.folderSchemaVersion)
        #expect(package.isFolder)
        try SharePackageValidator.validate(package, mode: .payload)

        let json = try SharePackageCoder.encode(package)
        defer { json.wipe() }
        let object = try #require(try JSONSerialization.jsonObject(with: json.withUnsafeBytes { Data($0) }) as? [String: Any])
        #expect(object["repository"] == nil)
        #expect(object["scope"] as? String == "folder")
        let folder = try #require(object["folder"] as? [String: Any])
        #expect(folder["name"] as? String == "Mobile App")
        #expect((folder["secrets"] as? [Any])?.count == 1)

        let decoded = try SharePackageCoder.decode(json)
        defer { decoded.wipeValues() }
        #expect(decoded == package)
        #expect(decoded.folder?.name == "Mobile App")
        let manifest = decoded.manifest()
        try SharePackageValidator.validate(manifest, mode: .manifest)
        #expect(manifest.flattenedItems.allSatisfy { $0.item.value == nil })
    }

    @Test func mixedDocumentsAreRefused() throws {
        func decode(_ text: String) -> ShareError? {
            let json = SecretBytes(utf8: text)
            defer { json.wipe() }
            do {
                _ = try SharePackageCoder.decode(json)
                return nil
            } catch {
                return error
            }
        }
        let header = """
            "schema":"io.fractalx.fxvault.share","schemaVersion":3,"packageId":"\(UUID().uuidString.lowercased())",\
            "createdAt":"2026-10-16T00:00:00Z","producer":{"app":"FX Vault","version":"0.7.0"},"sender":{"displayName":"Sam"}
            """
        let repository = #""repository":{"host":"github.com","owner":"octo-org","name":"service","githubRepoId":null}"#
        let folder = #""folder":{"name":"Mobile App","secrets":[],"variables":[]}"#
        #expect(decode("{\(header),\"scope\":\"folder\",\(repository),\(folder)}") == .invalidFile)
        #expect(decode("{\(header),\"scope\":\"repository\",\(repository),\(folder)}") == .invalidFile)
        #expect(decode("{\(header),\"scope\":\"folder\",\(folder)}") == nil)
    }

    // MARK: - Validator

    @Test func validatorRules() {
        func violation(_ mutate: (inout SharePackageModel) -> Void, mode: SharePackageValidator.Mode = .payload) -> SharePackageViolation? {
            var package = Self.folder()
            mutate(&package)
            return SharePackageValidator.violation(in: package, mode: mode)
        }
        #expect(violation { _ in } == nil)
        #expect(violation { $0.folder?.name = " Mobile" } == .invalidFolderName(.invalidName(.leadingOrTrailingWhitespace)))
        #expect(violation { $0.folder?.name = "Mobile\u{202E}" } == .invalidFolderName(.invalidName(.bidiCharacter)))
        #expect(violation { $0.folder = nil } == .scopeMismatch(.folder))
        #expect(violation { $0.schemaVersion = 2 } == .scopeMismatch(.folder))
        #expect(violation { $0.repository.owner = "octo-org" } == .scopeMismatch(.folder))
        #expect(violation { $0.repository.environments = [PackageFactory.environment("staging")] } == .scopeMismatch(.folder))
        #expect(violation { $0.scope = .repository } == .scopeMismatch(.repository))
        #expect(violation { $0.repository.secrets.append(PackageFactory.item("NO_VALUE", value: nil)) } == .valueStateMismatch)
        #expect(violation { $0.repository.secrets.append(PackageFactory.item("api_key")) } == .invalidItemName(.notNormalized))
        #expect(violation { $0.repository.variables.append(PackageFactory.item("API_URL")) } == .duplicateItem(kind: .variable, level: .repository))
        #expect(violation({ _ in }, mode: .manifest) == .valueInManifest)
        #expect(SharePackageValidator.violation(in: Self.folder().manifest(), mode: .manifest) == nil)
        let many = (0...Limits.maxFolderItems).map { PackageFactory.item("ITEM_\($0)", value: "v", syncState: .pending) }
        #expect(violation { $0.repository.variables = many } == .tooManyFolderItems(limit: Limits.maxFolderItems))
    }

    // MARK: - Import Into a repository

    @Test func intoRepositoryPutsTheItemsAtRepositoryLevelOrInAPartialEnvironment() throws {
        let package = Self.folder()
        defer { package.wipeValues() }
        let atRepository = try #require(package.intoRepository(owner: "owner-a", name: "repo-a", githubRepoID: nil, environmentName: nil))
        #expect(atRepository.scope == .repository)
        #expect(atRepository.folder == nil)
        #expect(atRepository.packageID == package.packageID)
        #expect(atRepository.repository.fullName == "owner-a/repo-a")
        #expect(atRepository.repository.secrets.map(\.name) == ["API_KEY"])
        #expect(atRepository.schemaVersion == SharePackageModel.wholeEnvironmentsSchemaVersion)
        try SharePackageValidator.validate(atRepository, mode: .payload)

        let inEnvironment = try #require(package.intoRepository(owner: "owner-a", name: "repo-a", githubRepoID: nil, environmentName: "staging"))
        #expect(inEnvironment.repository.secrets.isEmpty)
        #expect(inEnvironment.repository.environments.map(\.name) == ["staging"])
        #expect(inEnvironment.repository.environments.first?.includesBranchPolicy == false)
        #expect(inEnvironment.schemaVersion == SharePackageModel.partialEnvironmentsSchemaVersion)
        try SharePackageValidator.validate(inEnvironment, mode: .payload)

        #expect(PackageFactory.sample().intoRepository(owner: "owner-a", name: "repo-a", githubRepoID: nil, environmentName: nil) == nil)
    }

    @Test func thePlannerNeverPlansAFolder() {
        let package = Self.folder()
        defer { package.wipeValues() }
        let local = ShareLocalStateModel(repository: nil, now: PackageFactory.createdAt)
        #expect(throws: ShareError.invalidPackage(.scopeMismatch(.folder))) {
            _ = try ShareImportPlanner.plan(package, mode: .payload, local: local) { _, _ in nil }
        }
    }
}
