import Foundation
import Testing
import VaultCore

@Suite("Identifier")
struct IdentifierTests {
    @Test func textFormIsLowercase() throws {
        let id = try #require(RepoID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        #expect(id.uuidString == "e621e1f8-c36c-495a-93fc-0c247a3e6e5f")
        #expect(id.description == id.uuidString)
        #expect(RepoID(uuidString: id.uuidString) == id)
        #expect(RepoID(uuidString: "not-a-uuid") == nil)
    }

    @Test func bytesRoundTrip() throws {
        let id = EnvironmentID()
        #expect(id.bytes.count == EnvironmentID.byteCount)
        #expect(EnvironmentID(bytes: id.bytes) == id)
        #expect(EnvironmentID(bytes: [UInt8](repeating: 0, count: 15)) == nil)
        let known = try #require(ConfigItemID(uuidString: "00010203-0405-0607-0809-0a0b0c0d0e0f"))
        #expect(known.bytes == Array(0...15))
    }

    @Test func codableUsesTheLowercaseString() throws {
        let id = try #require(ConfigItemID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        let json = try JSONEncoder().encode([id])
        #expect(String(decoding: json, as: UTF8.self) == "[\"e621e1f8-c36c-495a-93fc-0c247a3e6e5f\"]")
        #expect(try JSONDecoder().decode([ConfigItemID].self, from: json) == [id])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ConfigItemID].self, from: Data("[\"x\"]".utf8))
        }
    }

    @Test func randomIdentifiersDiffer() {
        #expect(RepoID() != RepoID())
    }
}

@Suite("RepoCapabilityModel")
struct RepoCapabilityModelTests {
    @Test(arguments: [
        (ViewerPermission?.some(.admin), false, WriteCollaboratorPolicy.readOnly, RepoCapabilityModel.full),
        (.admin, true, .readOnly, .readOnly(.archived)),
        (.maintain, false, .readOnly, .readOnly(.adminRequired)),
        (.write, false, .readOnly, .readOnly(.adminRequired)),
        (.maintain, false, .repoLevelOnly, .repoLevelOnly),
        (.write, false, .repoLevelOnly, .repoLevelOnly),
        (.write, true, .repoLevelOnly, .readOnly(.archived)),
        (.triage, false, .repoLevelOnly, .readOnly(.adminRequired)),
        (.read, false, .repoLevelOnly, .readOnly(.adminRequired)),
        (nil, false, .repoLevelOnly, .readOnly(.adminRequired)),
    ])
    func derivesFromViewerPermission(
        permission: ViewerPermission?,
        archived: Bool,
        policy: WriteCollaboratorPolicy,
        expected: RepoCapabilityModel
    ) {
        let capability = RepoCapabilityModel(
            viewerPermission: permission,
            isArchived: archived,
            writePolicy: policy
        )
        #expect(capability == expected)
    }

    @Test func defaultPolicyTreatsWriteAsReadOnly() {
        #expect(WriteCollaboratorPolicy.default == .readOnly)
        #expect(RepoCapabilityModel(viewerPermission: .write, isArchived: false) == .readOnly(.adminRequired))
    }

    @Test func unavailableWinsOverPermissions() {
        let capability = RepoCapabilityModel(hasAdmin: true, hasPush: true, isArchived: false, isUnavailable: true)
        #expect(capability == .readOnly(.unavailable))
    }

    @Test func scopeChecks() {
        #expect(RepoCapabilityModel.full.canEditItems(at: .environment))
        #expect(RepoCapabilityModel.full.readOnlyReason(for: .environment) == nil)
        #expect(RepoCapabilityModel.repoLevelOnly.canEditItems(at: .repository))
        #expect(!RepoCapabilityModel.repoLevelOnly.canEditEnvironments)
        #expect(RepoCapabilityModel.repoLevelOnly.readOnlyReason(for: .environment) == .adminRequired)
        #expect(RepoCapabilityModel.repoLevelOnly.readOnlyReason(for: .repository) == nil)
        #expect(RepoCapabilityModel.readOnly(.archived).readOnlyReason(for: .repository) == .archived)
    }

    @Test func viewerPermissionParsing() {
        #expect(ViewerPermission(ghValue: "admin") == .admin)
        #expect(ViewerPermission(ghValue: "WRITE")?.hasPush == true)
        #expect(ViewerPermission(ghValue: "TRIAGE")?.hasPush == false)
        #expect(ViewerPermission(ghValue: "") == nil)
        #expect(ViewerPermission.admin.hasAdmin && !ViewerPermission.maintain.hasAdmin)
    }

    @Test func repoModelUsesStoredPermissions() {
        var repo = RepoModel(
            accountLogin: "octocat",
            githubID: nil,
            ownerLogin: "octocat",
            ownerType: .user,
            name: "api",
            visibility: .internal,
            hasAdmin: false,
            hasPush: true,
            origin: .created,
            importedAt: ManualClock.defaultStart
        )
        #expect(repo.fullName == "octocat/api")
        #expect(!repo.existsOnGitHub)
        #expect(repo.visibility.isPrivate)
        #expect(repo.capability == .readOnly(.adminRequired))
        #expect(repo.capability(writePolicy: .repoLevelOnly) == .repoLevelOnly)
        repo.hasAdmin = true
        #expect(repo.capability == .full)
        #expect(RepoVisibility(isPrivate: false) == .public)
    }
}

@Suite("EnvironmentModel and branch policies")
struct EnvironmentModelTests {
    private func environment(name: String, syncedName: String?) -> EnvironmentModel {
        EnvironmentModel(
            repositoryID: RepoID(),
            name: name,
            syncedName: syncedName,
            createdAt: ManualClock.defaultStart,
            updatedAt: ManualClock.defaultStart
        )
    }

    @Test func renameKinds() {
        let caseOnly = environment(name: "PRODUCCIÓN", syncedName: "Producción")
        #expect(caseOnly.hasCaseOnlyRename)
        #expect(!caseOnly.hasPendingRename)
        #expect(caseOnly.nameKey == caseOnly.syncedNameKey)

        let renamed = environment(name: "prod", syncedName: "production")
        #expect(renamed.hasPendingRename)
        #expect(!renamed.hasCaseOnlyRename)

        let unsynced = environment(name: "qa", syncedName: nil)
        #expect(!unsynced.isSynced && !unsynced.hasPendingRename && !unsynced.hasCaseOnlyRename)
        #expect(unsynced.hasPendingPolicyChange)
    }

    @Test func policyKindsAndFlags() throws {
        let envID = EnvironmentID()
        let active = BranchPatternModel(environmentID: envID, pattern: "release/*", type: .branch)
        let deleted = BranchPatternModel(
            environmentID: envID,
            pattern: "v*",
            type: .tag,
            githubPolicyID: 7,
            isDeleted: true
        )
        let custom = DeploymentBranchPolicyModel.custom([active, deleted])
        #expect(custom.kind == .custom)
        #expect(custom.patterns.count == 2)
        #expect(custom.activePatterns == [active])
        #expect(DeploymentBranchPolicyModel.all.patterns.isEmpty)
        #expect(deleted.isSynced && !active.isSynced)

        #expect(DeploymentBranchPolicyModel.all.gitHubFlags == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let protected = try #require(DeploymentBranchPolicyModel.protectedBranches.gitHubFlags)
        #expect(
            String(decoding: try encoder.encode(protected), as: UTF8.self)
                == "{\"custom_branch_policies\":false,\"protected_branches\":true}"
        )
        let customFlags = try #require(custom.gitHubFlags)
        #expect(
            String(decoding: try encoder.encode(customFlags), as: UTF8.self)
                == "{\"custom_branch_policies\":true,\"protected_branches\":false}"
        )
    }

    @Test func databaseRawValues() {
        #expect(BranchPolicyKind.allCases.map(\.rawValue) == ["all", "protected", "custom"])
        #expect(ConfigKind.allCases.map(\.rawValue) == ["secret", "variable"])
        #expect(OwnerType.allCases.map(\.rawValue) == ["User", "Organization"])
        #expect(RepoOrigin.allCases.map(\.rawValue) == ["imported", "created"])
        #expect(VerifyState.allCases.map(\.rawValue) == ["verified", "pending"])
        #expect(ConfigProvenance.allCases.map(\.rawValue) == ["local", "github", "share"])
        #expect(BranchPatternType.allCases.map(\.rawValue) == ["branch", "tag"])
    }

    @Test func createSpecUsesSnakeCase() throws {
        let spec = RepoCreateSpecModel(autoInit: true, gitignoreTemplate: "Swift", licenseTemplate: "mit", cloneAfter: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(spec), as: UTF8.self)
        #expect(json == "{\"auto_init\":true,\"clone_after\":true,\"gitignore_template\":\"Swift\",\"license_template\":\"mit\"}")
        #expect(try JSONDecoder().decode(RepoCreateSpecModel.self, from: Data(json.utf8)) == spec)
    }
}

@Suite("ConfigItemModel and sync status")
struct ConfigItemModelTests {
    typealias Facts = ConfigSyncStatus.Facts

    private static func facts(
        kind: ConfigKind = .secret,
        deleted: Bool = false,
        synced: Bool = true,
        renamed: Bool = false,
        changed: Bool = false,
        forcePush: Bool = false,
        value: ConfigValueState = .present,
        provenance: ConfigProvenance = .local
    ) -> Facts {
        Facts(
            kind: kind,
            isDeleted: deleted,
            isSynced: synced,
            isRenamed: renamed,
            isValueChanged: changed,
            forcePush: forcePush,
            valueState: value,
            provenance: provenance
        )
    }

    @Test(arguments: [
        (facts(), ConfigSyncStatus.synced),
        (facts(synced: false), .added),
        (facts(kind: .variable, synced: false), .added),
        (facts(renamed: true), .added),
        (facts(changed: true), .modified),
        (facts(forcePush: true), .willPush),
        (facts(changed: true, forcePush: true), .modified),
        (facts(forcePush: true, provenance: .share), .willPush),
        (facts(deleted: true), .deleted),
        (facts(deleted: true, value: .missing), .deleted),
        (facts(deleted: true, synced: false), .synced),
        (facts(value: .missing), .synced),
        (facts(synced: false, value: .missing), .blocked),
        (facts(renamed: true, value: .missing), .blocked),
        (facts(forcePush: true, value: .missing), .blocked),
        (facts(provenance: .share), .unverifiedShare),
        (facts(changed: true, provenance: .share), .modified),
        (facts(synced: false, provenance: .share), .added),
        (facts(provenance: .github), .synced),
    ])
    func derivesStatus(facts: Facts, expected: ConfigSyncStatus) {
        #expect(ConfigSyncStatus.derive(facts) == expected)
    }

    @Test func itemFacts() {
        let envID = EnvironmentID()
        let item = ConfigItemModel(
            repositoryID: RepoID(),
            scope: ConfigScope(environmentID: envID),
            kind: .secret,
            name: "API_KEY",
            valueState: .missing,
            syncedName: "API_KEY",
            syncStatus: .synced,
            createdAt: ManualClock.defaultStart,
            updatedAt: ManualClock.defaultStart
        )
        #expect(item.scope == .environment(envID))
        #expect(item.scope.environmentID == envID)
        #expect(item.scope.level == .environment)
        #expect(ConfigScope(environmentID: nil) == .repository)
        #expect(ConfigScope.repository.environmentID == nil)
        #expect(item.isSynced && item.isKindAndScopeLocked && !item.hasValue)
        #expect(item.nameKey == "API_KEY")
    }

    @Test func accountFacts() {
        var account = AccountModel(login: "Admin-Example", lastSeenAt: ManualClock.defaultStart)
        #expect(account.id == "admin-example")
        #expect(account.host == GitHubHostValidator.host)
        #expect(!account.isSSHAliasVerified)
        account.sshHostAlias = "github-personal"
        account.sshVerifiedLogin = "admin-example"
        #expect(account.isSSHAliasVerified)
        account.sshVerifiedLogin = "someone-else"
        #expect(!account.isSSHAliasVerified)
    }
}

@Suite("Limits and Timeouts")
struct LimitsTests {
    /// One rule for a place's value limit (1.0 F1): the item editor, Add file secret and the drop.
    @Test func aPlaceTakesGitHubsOrItsProvidersLimit() {
        #expect(DestinationRules.maxValueBytes(for: .scope(repositoryID: RepoID(), scope: .repository), provider: nil) == 48_000)
        #expect(DestinationRules.maxValueBytes(for: .folder(FolderID()), provider: nil) == 48_000)
        #expect(DestinationRules.maxValueBytes(for: .destination(DestinationID()), provider: .azureKeyVault) == 25_600)
        #expect(DestinationRules.maxValueBytes(for: .destination(DestinationID()), provider: nil) == 25_600, "the smallest until it is read")
    }

    @Test func planValues() {
        #expect(Limits.maxValueBytes == 48_000)
        #expect(Limits.writesPerMinute == 60)
        #expect(Limits.writesPerHour == 450)
        #expect(Limits.rateLimitRetries == 2)
        #expect(Limits.minPasswordLength == 12)
        #expect(Limits.minPasswordStrengthBits == 60)
        #expect(Limits.maxSharePayloadBytes == 16 * 1024 * 1024)
        #expect(Limits.maxShareFileBytes == Limits.maxSharePayloadBytes + 80)
        #expect(Limits.recoveryKeyGroupSize * Limits.recoveryKeyGroupCount == Limits.recoveryKeyCharacters)
        #expect(Limits.passwordKDFMemoryBytes == 268_435_456)
        #expect(Timeouts.rateLimitBackoff == .seconds(60))
        #expect(Timeouts.clipboardClear == .seconds(30))
        #expect(Timeouts.revealAllRemask == .seconds(60))
        #expect(Timeouts.autoLockDefault == Timeouts.autoLock(minutes: Timeouts.autoLockDefaultMinutes))
        #expect(Timeouts.autoLockOptionMinutes.contains(Timeouts.autoLockDefaultMinutes))
        #expect(Timeouts.passwordMaxAge == .seconds(14 * 24 * 3600))
    }

    @Test func durationTimeInterval() {
        #expect(Duration.seconds(90).timeInterval == 90)
        #expect(Duration.milliseconds(1500).timeInterval == 1.5)
        #expect(Duration.zero.timeInterval == 0)
    }
}
