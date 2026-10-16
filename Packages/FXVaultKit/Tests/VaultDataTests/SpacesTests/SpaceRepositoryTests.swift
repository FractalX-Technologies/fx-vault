import Foundation
import FXVaultTestSupport
import GitHubKit
import SharingKit
import SyncEngine
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// One Mac of a shared space test: its vault over the shared simulated GitHub, its teammate keys
/// and its spaces. Synthetic names only (user-a, user-b; tasks/lessons.md).
struct SpaceMac {
    let harness: SyncHarness
    let me: SpaceLocalIdentityModel
    let deviceID: TeamDeviceID

    static func make(_ name: String, login: String, github: GitHubSimulator) async throws -> SpaceMac {
        let harness = try await SyncHarness.make(github: github)
        let me = SpaceLocalIdentityModel(login: login, displayName: name, macName: "\(name)'s Mac")
        let deviceID = try TeamRepository(session: harness.session, clock: harness.clock).deviceKeys().deviceID
        return SpaceMac(harness: harness, me: me, deviceID: deviceID)
    }

    var team: TeamRepository {
        TeamRepository(session: harness.session, clock: harness.clock)
    }

    var spaces: SpaceRepository {
        harness.spaces
    }

    func card() throws -> TeamCardModel {
        try team.deviceKeys().card(login: me.login, displayName: me.displayName, macName: me.macName)
    }

    /// Pairs two Macs (what Add Teammate stores on each side).
    static func pair(_ lhs: SpaceMac, _ rhs: SpaceMac) throws {
        try lhs.team.addTeammate(try rhs.card())
        try rhs.team.addTeammate(try lhs.card())
    }

    /// What peer sync does: every version `source` has that this Mac lacks, one space at a time.
    @discardableResult
    func pull(from source: SpaceMac) throws -> [SpaceReceiveOutcomeModel] {
        var outcomes: [SpaceReceiveOutcomeModel] = []
        for head in try source.spaces.heads(sharedWith: deviceID) {
            let mine = try spaces.spaces().first { $0.id == head.spaceID }.map { UInt64($0.headVersion) } ?? 0
            guard head.version > mine else { continue }
            let versions = try (mine + 1...head.version).map { number in
                try #require(try source.spaces.version(number, of: head.spaceID, for: deviceID))
            }
            outcomes.append(try spaces.receive(versions, spaceID: head.spaceID, from: source.deviceID))
        }
        return outcomes
    }

    func item(_ name: String, kind: ConfigKind) throws -> ConfigItemState {
        try #require(try harness.item(name, kind: kind))
    }

    func value(_ name: String, kind: ConfigKind) throws -> String? {
        try harness.value(try item(name, kind: kind).id)
    }

    func edit(_ name: String, kind: ConfigKind, to value: String) throws {
        try harness.config.editValue(try item(name, kind: kind).id, value: SecretBytes(utf8: value))
    }
}

/// Shared spaces end to end (v0.6.0, tasks/todo.md S1–S9) over one simulated GitHub and two or
/// three vaults: share, pull, gate, claim and publish, drafts on top, members and keys, history.
@Suite("SpaceRepository")
struct SpaceRepositoryTests {
    static let marker = GitHubNameValidator.spaceMarkerName

    static func marker(_ github: GitHubSimulator, environment: String? = nil) -> SpaceMarkerModel? {
        github.variable(marker, environment: environment).flatMap { SpaceMarkerModel.decode($0.value) }
    }

    /// Ana pushes FXV_URL and FXV_TOKEN, Ben imports the repository (the token's value is
    /// missing for him), they pair, Ana shares the repository level with Ben and Ben pulls v1.
    static func sharedPair() async throws -> (GitHubSimulator, SpaceMac, SpaceMac, SpaceID) {
        let github = GitHubSimulator()
        let ana = try await SpaceMac.make("Ana", login: "user-a", github: github)
        let ben = try await SpaceMac.make("Ben", login: "user-b", github: github)
        try await ana.harness.importRepository()
        try ana.harness.add("FXV_URL", kind: .variable, value: "https://example.com")
        try ana.harness.add("FXV_TOKEN", kind: .secret, value: "token-one")
        _ = try await ana.harness.runSync()
        try await ben.harness.importRepository()
        try SpaceMac.pair(ana, ben)
        let repositoryID = try ana.harness.repository().id
        let space = try await ana.spaces.share(
            repositoryID: repositoryID,
            scope: .repository,
            with: [ben.deviceID.hex],
            me: ana.me,
            reason: "Start sharing"
        )
        try ben.pull(from: ana)
        return (github, ana, ben, space)
    }

    @Test func sharingPublishesVersionOneAndTheTeammateGetsValuesItCouldNotRead() async throws {
        let github = GitHubSimulator()
        let ana = try await SpaceMac.make("Ana", login: "user-a", github: github)
        let ben = try await SpaceMac.make("Ben", login: "user-b", github: github)
        try await ana.harness.importRepository()
        try ana.harness.add("FXV_URL", kind: .variable, value: "https://example.com")
        try ana.harness.add("FXV_TOKEN", kind: .secret, value: "token-one")
        let repositoryID = try ana.harness.repository().id
        #expect(try ana.spaces.readiness(repositoryID: repositoryID, scope: .repository).pendingNames == ["FXV_TOKEN", "FXV_URL"])
        _ = try await ana.harness.runSync()
        try await ben.harness.importRepository()
        #expect(try ben.item("FXV_TOKEN", kind: .secret).hasValue == false)
        #expect(try ben.harness.spaces.readiness(repositoryID: ben.harness.repository().id, scope: .repository).missingValueNames == ["FXV_TOKEN"])
        try SpaceMac.pair(ana, ben)
        #expect(try ana.spaces.readiness(repositoryID: repositoryID, scope: .repository).isReady)

        let space = try await ana.spaces.share(repositoryID: repositoryID, scope: .repository, with: [ben.deviceID.hex], me: ana.me, reason: "Start sharing")

        let marker = try #require(Self.marker(github))
        #expect(marker.spaceID == space && marker.version == 1 && marker.state == .published && marker.login == "user-a")
        #expect(try ana.spaces.spaces().map(\.isPublishing) == [false])
        #expect(try ana.harness.states().allSatisfy { $0.name != Self.marker })
        await #expect(throws: SpaceRepositoryError.alreadyShared) {
            try await ana.spaces.share(repositoryID: repositoryID, scope: .repository, with: [ben.deviceID.hex], me: ana.me, reason: "")
        }

        let outcomes = try ben.pull(from: ana)
        #expect(outcomes.count == 1)
        let token = try ben.item("FXV_TOKEN", kind: .secret)
        #expect(try ben.harness.value(token.id) == "token-one")
        #expect(token.model.syncStatus == .synced)
        #expect(try ben.harness.pendingCount() == 0)
        #expect(try ben.pull(from: ana).isEmpty)
        let detail = try ben.spaces.detail(space)
        #expect(detail.members.map(\.name) == ["Ana", "Ben"])
        #expect(detail.members.map(\.isThisMac) == [false, true])
        #expect(detail.isMember)
    }

    @Test func aScopeAnotherMemberAlreadySharesCannotBeSharedAgain() async throws {
        let (github, ana, _, _) = try await Self.sharedPair()
        let cara = try await SpaceMac.make("Cara", login: "user-c", github: github)
        try await cara.harness.importRepository()
        try SpaceMac.pair(ana, cara)
        let token = try cara.item("FXV_TOKEN", kind: .secret)
        try cara.harness.config.fillValue(token.id, value: SecretBytes(utf8: "token-one"), pushOnNextSync: false)
        await #expect(throws: SpaceRepositoryError.sharedOnGitHub) {
            try await cara.spaces.share(
                repositoryID: try cara.harness.repository().id,
                scope: .repository,
                with: [ana.deviceID.hex],
                me: cara.me,
                reason: ""
            )
        }
    }

    @Test func aBehindMacCannotPushUntilItGetsTheTeammatesVersion() async throws {
        let (github, ana, ben, space) = try await Self.sharedPair()

        try ana.edit("FXV_TOKEN", kind: .secret, to: "token-two")
        let first = try await ana.harness.runSync(spaceReason: "Rotate the token")
        #expect(first.result.failed.isEmpty && first.result.blocked.isEmpty && first.result.warnings.isEmpty)
        #expect(Self.marker(github)?.version == 2)
        #expect(Self.marker(github)?.state == .published)

        try ben.edit("FXV_URL", kind: .variable, to: "https://example.org")
        let blocked = try await ben.harness.runSync()
        #expect(blocked.result.blocked.map(\.outcome) == [
            .blocked(.space(SyncSpaceBlockModel(spaceID: space, decision: .behind(version: 2, login: "user-a")))),
        ])
        #expect(github.variable("FXV_URL")?.value == "https://example.com")

        try ben.pull(from: ana)
        #expect(try ben.value("FXV_TOKEN", kind: .secret) == "token-two")
        #expect(try ben.item("FXV_URL", kind: .variable).model.syncStatus == .modified)
        let pushed = try await ben.harness.runSync()
        #expect(pushed.result.failed.isEmpty && pushed.result.blocked.isEmpty)
        #expect(github.variable("FXV_URL")?.value == "https://example.org")
        #expect(Self.marker(github)?.version == 3)

        try ana.pull(from: ben)
        #expect(try ana.value("FXV_URL", kind: .variable) == "https://example.org")
        #expect(try ana.harness.pendingCount() == 0)

        let history = try ana.spaces.history(space)
        #expect(history.map(\.version) == [3, 2, 1])
        #expect(history.map(\.changedNames) == [["FXV_URL"], ["FXV_TOKEN"], ["FXV_TOKEN", "FXV_URL"]])
        #expect(history.map(\.reason) == ["", "Rotate the token", "Start sharing"])
        #expect(history.map(\.authorName) == ["Ben", "Ana", "Ana"])
        #expect(history.map(\.kind) == [.published, .published, .shared])
        let token = try ana.spaces.itemHistory(space, kind: .secret, name: "FXV_TOKEN")
        #expect(token.map(\.version) == [2, 1])
        #expect(token[0].fingerprint != token[1].fingerprint)
        #expect(try ben.spaces.itemHistory(space, kind: .secret, name: "FXV_TOKEN").map(\.fingerprint) == token.map(\.fingerprint))
    }

    @Test func driftInABehindSharedScopeIsATeammatesChange() async throws {
        let (_, ana, ben, space) = try await Self.sharedPair()
        try ana.edit("FXV_TOKEN", kind: .secret, to: "token-two")
        _ = try await ana.harness.runSync()

        let report = try await ben.harness.drift.refresh(try ben.harness.repository().id)
        #expect(report.spaces == [DriftSpaceModel(spaceID: space, scope: .repository, decision: .behind(version: 2, login: "user-a"))])
        let finding = try #require(report.drifts.first)
        #expect(report.space(of: finding)?.spaceID == space)

        try ben.pull(from: ana)
        let after = try await ben.harness.drift.refresh(try ben.harness.repository().id)
        #expect(after.spaces.isEmpty)
        #expect(after.drifts.isEmpty, "the teammate's version explains GitHub's change")
    }

    @Test func aTeammatesVersionKeepsALocalDraftOnTop() async throws {
        let (github, ana, ben, space) = try await Self.sharedPair()
        try ana.edit("FXV_URL", kind: .variable, to: "https://ana.example.com")
        _ = try await ana.harness.runSync()
        try ben.edit("FXV_URL", kind: .variable, to: "https://ben.example.com")

        var applied = SpaceApplyResultModel()
        applied.conflictNames = ["FXV_URL"]
        #expect(try ben.pull(from: ana) == [.stored(spaceID: space, version: 2, applied: applied)])
        let url = try ben.item("FXV_URL", kind: .variable)
        #expect(url.model.syncStatus == .modified)
        #expect(try ben.harness.value(url.id) == "https://ben.example.com")
        #expect(try ben.harness.syncedValue(url.id) == "https://ana.example.com")

        let pushed = try await ben.harness.runSync()
        #expect(pushed.result.blocked.isEmpty && pushed.result.failed.isEmpty)
        #expect(github.variable("FXV_URL")?.value == "https://ben.example.com")
        #expect(Self.marker(github)?.version == 3)
    }

    @Test func aPartialFailurePublishesOnlyWhatGitHubConfirmed() async throws {
        let (github, ana, ben, space) = try await Self.sharedPair()
        try ana.edit("FXV_URL", kind: .variable, to: "https://ana.example.com")
        try ana.edit("FXV_TOKEN", kind: .secret, to: "token-two")
        github.enqueue(
            .failure(stderr: "failed to set secret \"FXV_TOKEN\": HTTP 403: Must have admin rights to Repository. (https://api.github.com/repos/owner-a/api/actions/secrets/FXV_TOKEN)"),
            matching: GHMatch.secretSet("FXV_TOKEN")
        )

        let outcome = try await ana.harness.runSync()

        #expect(outcome.result.failed.count == 1)
        #expect(Self.marker(github)?.version == 2)
        let history = try ana.spaces.history(space)
        #expect(history.first?.changedNames == ["FXV_URL"])
        try ben.pull(from: ana)
        #expect(try ben.value("FXV_URL", kind: .variable) == "https://ana.example.com")
        #expect(try ben.value("FXV_TOKEN", kind: .secret) == "token-one", "GitHub still holds the old token")
        #expect(try ana.item("FXV_TOKEN", kind: .secret).model.syncStatus == .modified)
    }

    @Test func restoringAnOlderValueStagesItAsALocalChange() async throws {
        let (_, ana, _, space) = try await Self.sharedPair()
        try ana.edit("FXV_TOKEN", kind: .secret, to: "token-two")
        _ = try await ana.harness.runSync()

        let old = try #require(try ana.spaces.value(space, version: 1, kind: .secret, name: "FXV_TOKEN"))
        #expect(old.utf8String() == "token-one")
        old.wipe()
        try ana.spaces.restore(space, version: 1, kind: .secret, name: "FXV_TOKEN")
        #expect(try ana.value("FXV_TOKEN", kind: .secret) == "token-one")
        #expect(try ana.item("FXV_TOKEN", kind: .secret).model.syncStatus == .modified)
    }

    @Test func addingAMemberGivesItTheWholeHistory() async throws {
        let (github, ana, ben, space) = try await Self.sharedPair()
        let cara = try await SpaceMac.make("Cara", login: "user-c", github: github)
        try await cara.harness.importRepository()
        try SpaceMac.pair(ana, cara)

        try await ana.spaces.addMembers(space, teammateIDs: [cara.deviceID.hex], me: ana.me)

        #expect(Self.marker(github)?.version == 2)
        #expect(try ana.spaces.detail(space).members.map(\.name) == ["Ana", "Ben", "Cara"])
        #expect(try ana.spaces.detail(space).summary.epoch == 1)
        let outcomes = try cara.pull(from: ana)
        #expect(outcomes == [.stored(spaceID: space, version: 2, applied: SpaceApplyResultModel(updated: 1))])
        #expect(try cara.value("FXV_TOKEN", kind: .secret) == "token-one")
        #expect(try cara.spaces.history(space).map(\.version) == [2, 1])
        // Ben relays from Cara too: the log is the same everywhere.
        #expect(try ben.pull(from: cara).count == 1)
        #expect(try ben.spaces.detail(space).summary.headVersion == 2)
    }

    @Test func removingAMemberStartsANewEpochAndListsTheSecretsToRotate() async throws {
        let (github, ana, ben, space) = try await Self.sharedPair()

        let checklist = try await ana.spaces.removeMembers(space, deviceIDs: [ben.deviceID.hex], me: ana.me)

        #expect(checklist.secretNames == ["FXV_TOKEN"])
        let detail = try ana.spaces.detail(space)
        #expect(detail.members.map(\.name) == ["Ana"])
        #expect(detail.summary.epoch == 2 && detail.summary.headVersion == 2)
        #expect(Self.marker(github)?.version == 2)
        #expect(try ana.spaces.heads(sharedWith: ben.deviceID).isEmpty)
        #expect(try ana.spaces.version(2, of: space, for: ben.deviceID) == nil)

        // Relayed anyway, the removal reaches Ben: he can no longer publish.
        let relayed = try #require(try ana.spaces.version(2, of: space, for: ana.deviceID))
        #expect(try ben.spaces.receive([relayed], spaceID: space, from: ana.deviceID) == .stored(spaceID: space, version: 2, applied: SpaceApplyResultModel()))
        #expect(try ben.spaces.gate(spaceID: space, markerText: github.variable(Self.marker)?.value) == .notAMember)
        #expect(try ben.spaces.detail(space).isMember == false)

        // Ana's next version uses a key Ben never got: it is stored but not applied for him.
        try ana.edit("FXV_TOKEN", kind: .secret, to: "token-rotated")
        _ = try await ana.harness.runSync()
        let next = try #require(try ana.spaces.version(3, of: space, for: ana.deviceID))
        #expect(try ben.spaces.receive([next], spaceID: space, from: ana.deviceID) == .stored(spaceID: space, version: 3, applied: SpaceApplyResultModel()))
        #expect(try ben.value("FXV_TOKEN", kind: .secret) == "token-one")
        await #expect(throws: SpaceRepositoryError.invalidMembers) {
            try await ana.spaces.removeMembers(space, deviceIDs: [ana.deviceID.hex], me: ana.me)
        }
    }

    @Test func aTamperedOrForeignVersionIsRefusedAndNothingIsStored() async throws {
        let (_, ana, ben, space) = try await Self.sharedPair()
        try ana.edit("FXV_URL", kind: .variable, to: "https://ana.example.com")
        _ = try await ana.harness.runSync()
        var tampered = try #require(try ana.spaces.version(2, of: space, for: ben.deviceID))
        tampered[tampered.index(tampered.endIndex, offsetBy: -80)] ^= 0x01

        #expect(throws: SpaceRepositoryError.self) {
            try ben.spaces.receive([tampered], spaceID: space, from: ana.deviceID)
        }
        #expect(try ben.spaces.detail(space).summary.headVersion == 1)
        #expect(try ben.value("FXV_URL", kind: .variable) == "https://example.com")
        let valid = try #require(try ana.spaces.version(2, of: space, for: ben.deviceID))
        #expect(throws: SpaceRepositoryError.log(.wrongSpace)) {
            try ben.spaces.receive([valid], spaceID: SpaceID(), from: ana.deviceID)
        }
        #expect(try ben.spaces.receive([valid, valid], spaceID: space, from: ana.deviceID) == .stored(spaceID: space, version: 2, applied: SpaceApplyResultModel(updated: 1)))
        #expect(try ben.spaces.receive([valid], spaceID: space, from: ana.deviceID) == .alreadyHave)
    }

    @Test func aNewSpaceNeedsTheRepositoryAndMembership() async throws {
        let (github, ana, _, space) = try await Self.sharedPair()
        let cara = try await SpaceMac.make("Cara", login: "user-c", github: github)
        try SpaceMac.pair(ana, cara)
        let log = try #require(try ana.spaces.version(1, of: space, for: ana.deviceID))
        #expect(try cara.spaces.receive([log], spaceID: space, from: ana.deviceID) == .notAMember)
        try await ana.spaces.addMembers(space, teammateIDs: [cara.deviceID.hex], me: ana.me)
        let versions = try [1, 2].map { try #require(try ana.spaces.version($0, of: space, for: cara.deviceID)) }
        #expect(try cara.spaces.receive(versions, spaceID: space, from: ana.deviceID) == .repositoryMissing)
        #expect(try cara.spaces.receive(Array(versions.dropFirst()), spaceID: space, from: ana.deviceID) == .gap)
        #expect(try cara.spaces.spaces().isEmpty)
    }

    @Test func aSpaceBeingPublishedIsNotAdvancedByATeammate() async throws {
        let (_, ana, ben, space) = try await Self.sharedPair()
        try ana.edit("FXV_URL", kind: .variable, to: "https://ana.example.com")
        _ = try await ana.harness.runSync()
        _ = try ben.spaces.claim(spaceID: space)
        let next = try #require(try ana.spaces.version(2, of: space, for: ben.deviceID))
        #expect(try ben.spaces.receive([next], spaceID: space, from: ana.deviceID) == .busy)
        try ben.spaces.abandonClaim(spaceID: space)
        #expect(try ben.spaces.receive([next], spaceID: space, from: ana.deviceID) == .stored(spaceID: space, version: 2, applied: SpaceApplyResultModel(updated: 1)))
    }

    @Test func spaceKeysAreSealedAndSurviveALockAndADEKRotation() async throws {
        let (_, ana, _, space) = try await Self.sharedPair()
        let stored = try ana.harness.database.read { tx in try SpaceStore(database: ana.harness.database).fetchKeys(spaceID: space, in: tx) }
        #expect(stored.map(\.epoch) == [1])

        ana.harness.manager.lock()
        #expect(throws: SpaceRepositoryError.vault(.locked)) { try ana.spaces.history(space) }
        #expect(try ana.spaces.spaces().count == 1, "summaries stay readable while locked")
        try await ana.harness.manager.unlock(password: SyncFixture.password)
        let recovery = try await ana.harness.manager.rotateDEK(password: SyncFixture.password)
        recovery.wipe()
        #expect(try ana.spaces.history(space).map(\.version) == [1])
        let rotated = try ana.harness.database.read { tx in try SpaceStore(database: ana.harness.database).fetchKeys(spaceID: space, in: tx) }
        #expect(rotated.first?.keyCiphertext != stored.first?.keyCiphertext)
    }

    @Test func aCrashBetweenPushAndPublishIsFinishedAtTheNextUnlock() async throws {
        let (github, ana, _, space) = try await Self.sharedPair()
        // The claim reached GitHub, the push too, then the app stopped before publishing.
        let claim = try ana.spaces.claim(spaceID: space)
        github.addVariable(Self.marker, value: claim)
        try ana.edit("FXV_URL", kind: .variable, to: "https://ana.example.com")
        let review = try await ana.harness.sync.preflight()
        #expect(review.preflight.repositories[0].spaces.map(\.decision) == [.clear])
        #expect(try ana.spaces.spaces().map(\.isPublishing) == [true])

        try await ana.harness.sync.prepareAfterUnlock()

        #expect(try ana.spaces.spaces().map(\.isPublishing) == [false])
        #expect(Self.marker(github)?.state == .published)
        #expect(Self.marker(github)?.version == 1, "nothing new on GitHub yet: the head is published again")
    }
}
