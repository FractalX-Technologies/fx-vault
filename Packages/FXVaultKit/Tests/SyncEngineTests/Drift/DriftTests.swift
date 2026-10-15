import Foundation
import GitHubKit
import Testing
import SyncEngine
import VaultCore

/// §7.7: every drift row times both resolutions (as pure state effects), lists over 100 items,
/// the pending-verification skip and journal-based deletion suppression.
@Suite("DriftTests")
struct DriftTests {
    // MARK: - Variable modified

    @Test func variableModifiedBothResolutions() throws {
        let row = Fx.syncedItem("API_URL", kind: .variable, value: "old")
        let local = Fx.snapshot(items: [row])
        let drifts = RemoteFx.detect(local, repository: RemoteFx.scope(variables: [RemoteFx.variable("API_URL", value: "new", updatedAt: RemoteFx.tuesday)]))
        let drift = try #require(drifts.only)
        let remoteFP = Fx.fp("new", row: row.id)
        #expect(drift.kind == .variableModified)
        #expect(!drift.isConflict)
        #expect(drift.remoteUpdatedAt == RemoteFx.tuesday)
        #expect(drift.subject == .item(DriftItemSubjectModel(
            key: RemoteItemKeyModel(scope: .repository, kind: .variable, name: "API_URL"),
            kind: .variable,
            name: "API_URL",
            environmentName: nil,
            environmentID: nil,
            itemID: row.id
        )))
        #expect(drift.keepLocal.effects == [.rebaseVariable(itemID: row.id, remoteFingerprint: remoteFP)])
        #expect(drift.acceptGitHub.effects == [.adoptRemoteVariable(itemID: row.id, remoteFingerprint: remoteFP)])
        #expect(drift.keepLocal.isAvailable && drift.acceptGitHub.isAvailable)
        #expect(drift.resolution(.keepLocal) == drift.keepLocal)
        #expect(drift.resolution(.acceptGitHub) == drift.acceptGitHub)
        #expect(drift.id == "variable_modified:item|variable|API_URL|repo")
    }

    @Test func variableUnchangedIsNoDrift() {
        let row = Fx.syncedItem("API_URL", kind: .variable, value: "same")
        let drifts = RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(variables: [RemoteFx.variable("API_URL", value: "same")]))
        #expect(drifts.isEmpty)
    }

    @Test func variableModifiedWhileModifiedLocallyIsAConflict() throws {
        let row = Fx.item("API_URL", kind: .variable, value: "mine", synced: "API_URL", syncedValue: "old")
        let drifts = RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(variables: [RemoteFx.variable("API_URL", value: "theirs")]))
        #expect(try #require(drifts.only).isConflict)
    }

    @Test func keepLocalVariableMakesItAPendingModify() throws {
        // Applying "Keep local" (synced_fp := fp(remote)) leaves a modify for the next Sync.
        var row = Fx.item("API_URL", kind: .variable, value: "mine", synced: "API_URL", syncedValue: "old")
        let drift = try #require(RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(variables: [RemoteFx.variable("API_URL", value: "theirs")])).only)
        guard case .rebaseVariable(_, let fingerprint) = try #require(drift.keepLocal.effects.first) else {
            Issue.record("expected rebaseVariable")
            return
        }
        row.syncedFingerprint = fingerprint
        let changes = ChangeSetBuilder.build(Fx.snapshot(items: [row])).changes.map(Describe.change)
        #expect(changes == ["set_variable repo API_URL update modified"])
    }

    // MARK: - Secret modified

    @Test func secretModifiedBothResolutions() throws {
        let row = Fx.syncedItem("API_TOKEN", remoteUpdatedAt: RemoteFx.monday)
        let drifts = RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(secrets: [RemoteFx.secret("API_TOKEN", updatedAt: RemoteFx.tuesday)]))
        let drift = try #require(drifts.only)
        #expect(drift.kind == .secretModified)
        #expect(drift.remoteUpdatedAt == RemoteFx.tuesday)
        #expect(drift.keepLocal.effects == [.rebaseSecret(itemID: row.id, remoteUpdatedAt: RemoteFx.tuesday, forcePush: true)])
        #expect(drift.acceptGitHub.effects == [.clearSecretValue(itemID: row.id, remoteUpdatedAt: RemoteFx.tuesday)])
        #expect(drift.acceptGitHub.followUp == .promptFillValue(row.id))
    }

    @Test func secretModifiedKeepLocalNeedsAValue() throws {
        let row = Fx.syncedItem("API_TOKEN", value: nil, remoteUpdatedAt: RemoteFx.monday)
        let drift = try #require(RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(secrets: [RemoteFx.secret("API_TOKEN", updatedAt: RemoteFx.tuesday)])).only)
        #expect(drift.keepLocal == .unavailable(.keepLocal, .valueMissing))
        #expect(drift.acceptGitHub.isAvailable)
    }

    @Test func secretTimestampsCompareAtStoredPrecision() throws {
        // gh prints nanoseconds; the vault stores milliseconds (DatabaseTimestamp).
        let stored = try #require(ISO8601DateFormatter.fractional.date(from: "2026-10-02T11:30:00.123Z"))
        let subMillisecond: TimeInterval = 0.000_456
        let listed = stored.addingTimeInterval(subMillisecond)
        let row = Fx.syncedItem("DSN", remoteUpdatedAt: stored)
        #expect(RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(secrets: [RemoteFx.secret("DSN", updatedAt: listed)])).isEmpty)
        #expect(DriftDetector.isSameTimestamp(nil, nil))
        #expect(!DriftDetector.isSameTimestamp(nil, stored))
        #expect(!DriftDetector.isSameTimestamp(stored, stored.addingTimeInterval(SyncEngineConstants.timestampTolerance)))
    }

    @Test func secretWithoutARecordedTimestampDrifts() throws {
        let row = Fx.syncedItem("API_TOKEN", remoteUpdatedAt: nil)
        let drift = try #require(RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(secrets: [RemoteFx.secret("API_TOKEN")])).only)
        #expect(drift.kind == .secretModified)
    }

    @Test func keepLocalSecretAcknowledgesTheRemoteBase() throws {
        // After "Keep local" the row pushes (force_push) and its base equals the listing, so
        // a second detection on the same listing is clean (no D27 deadlock).
        var row = Fx.syncedItem("API_TOKEN", remoteUpdatedAt: RemoteFx.monday)
        let listing = RemoteFx.scope(secrets: [RemoteFx.secret("API_TOKEN", updatedAt: RemoteFx.tuesday)])
        let drift = try #require(RemoteFx.detect(Fx.snapshot(items: [row]), repository: listing).only)
        guard case .rebaseSecret(_, let date, let forcePush) = try #require(drift.keepLocal.effects.first) else {
            Issue.record("expected rebaseSecret")
            return
        }
        row.remoteUpdatedAt = date
        row.forcePush = forcePush
        #expect(RemoteFx.detect(Fx.snapshot(items: [row]), repository: listing).isEmpty)
        #expect(ChangeSetBuilder.build(Fx.snapshot(items: [row])).changes.map(Describe.change) == ["set_secret repo API_TOKEN update force"])
    }

    @Test func modifiedRemotelyWhileDeletedLocallyIsAConflict() throws {
        let row = Fx.item("OLD_TOKEN", synced: "OLD_TOKEN", syncedValue: "v1", deleted: true, remoteUpdatedAt: RemoteFx.monday)
        let drift = try #require(RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(secrets: [RemoteFx.secret("OLD_TOKEN", updatedAt: RemoteFx.tuesday)])).only)
        #expect(drift.isConflict)
        #expect(drift.keepLocal.effects == [.rebaseSecret(itemID: row.id, remoteUpdatedAt: RemoteFx.tuesday, forcePush: false)])
    }

    // MARK: - Remote added

    @Test func remoteAddedBothResolutions() throws {
        let production = Fx.syncedEnv("production")
        let local = Fx.snapshot(environments: [production])
        let drifts = RemoteFx.detect(local, environments: [
            try RemoteFx.environment("production", id: 1, listing: RemoteFx.scope(
                secrets: [RemoteFx.secret("NEW_SECRET")],
                variables: [RemoteFx.variable("NEW_VAR", value: "x")]
            )),
        ])
        #expect(drifts.count == 2)
        for drift in drifts {
            guard case .item(let subject) = drift.subject else {
                Issue.record("expected an item")
                continue
            }
            let placement = DriftItemPlacementModel(
                environmentID: production.id,
                kind: subject.kind,
                name: subject.name,
                remoteUpdatedAt: RemoteFx.monday
            )
            #expect(drift.kind == .remoteAdded)
            #expect(!drift.isConflict)
            #expect(subject.environmentName == "production")
            #expect(drift.keepLocal.effects == [.createTombstone(placement)])
            #expect(drift.acceptGitHub.effects == [.importItem(placement)])
        }
    }

    @Test func remoteAddedOverANeverSyncedRowIsAConflict() throws {
        let row = Fx.item("API_URL", kind: .variable, value: "mine")
        let drift = try #require(RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(variables: [RemoteFx.variable("API_URL", value: "theirs")])).only)
        let fingerprint = Fx.fp("theirs", row: row.id)
        #expect(drift.kind == .remoteAdded)
        #expect(drift.isConflict)
        #expect(drift.keepLocal.effects == [.adoptRemoteIdentity(itemID: row.id, remoteName: "API_URL", remoteUpdatedAt: RemoteFx.monday, remoteFingerprint: fingerprint)])
        #expect(drift.acceptGitHub.effects == [.replaceWithRemote(itemID: row.id, remoteName: "API_URL", remoteUpdatedAt: RemoteFx.monday, remoteFingerprint: fingerprint)])
        #expect(drift.acceptGitHub.followUp == nil)
    }

    @Test func remoteAddedOverANeverSyncedSecret() throws {
        let row = Fx.item("TOKEN", value: nil)
        let drift = try #require(RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(secrets: [RemoteFx.secret("TOKEN")])).only)
        #expect(drift.keepLocal == .unavailable(.keepLocal, .valueMissing))
        #expect(drift.acceptGitHub.followUp == .promptFillValue(row.id))
    }

    @Test func remoteAddedAtARenameTargetDetachesTheOldIdentity() throws {
        let row = Fx.item("NEW_NAME", synced: "OLD_NAME", syncedValue: "v1", remoteUpdatedAt: RemoteFx.monday)
        let drifts = RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(secrets: [
            RemoteFx.secret("OLD_NAME"),
            RemoteFx.secret("NEW_NAME", updatedAt: RemoteFx.tuesday),
        ]))
        let drift = try #require(drifts.only)
        #expect(drift.isConflict)
        #expect(drift.keepLocal.effects == [
            .detachSyncedIdentity(itemID: row.id),
            .adoptRemoteIdentity(itemID: row.id, remoteName: "NEW_NAME", remoteUpdatedAt: RemoteFx.tuesday, remoteFingerprint: nil),
        ])
        #expect(drift.acceptGitHub.effects.first == .detachSyncedIdentity(itemID: row.id))
    }

    // MARK: - Remote deleted

    @Test func remoteDeletedBothResolutions() throws {
        let row = Fx.syncedItem("GONE_URL", kind: .variable)
        let drift = try #require(RemoteFx.detect(Fx.snapshot(items: [row])).only)
        #expect(drift.kind == .remoteDeleted)
        #expect(!drift.isConflict)
        #expect(drift.keepLocal.effects == [.markItemUnsynced(itemID: row.id)])
        #expect(drift.acceptGitHub.effects == [.deleteLocalItem(itemID: row.id)])
    }

    @Test func remoteDeletedKeepLocalNeedsAValue() throws {
        let row = Fx.syncedItem("GONE_TOKEN", value: nil)
        let drift = try #require(RemoteFx.detect(Fx.snapshot(items: [row])).only)
        #expect(drift.keepLocal == .unavailable(.keepLocal, .valueMissing))
    }

    @Test func remoteDeletedWhileRenamedLocallyIsAConflict() throws {
        let row = Fx.item("NEW_NAME", synced: "OLD_NAME", syncedValue: "v1")
        let drift = try #require(RemoteFx.detect(Fx.snapshot(items: [row])).only)
        #expect(drift.kind == .remoteDeleted)
        #expect(drift.isConflict)
    }

    @Test func tombstoneAlreadyGoneIsNoDrift() {
        let row = Fx.item("GONE", synced: "GONE", syncedValue: "v1", deleted: true)
        #expect(RemoteFx.detect(Fx.snapshot(items: [row])).isEmpty)
    }

    @Test func keepLocalAfterRemoteDeleteIsAPendingAdd() throws {
        var row = Fx.syncedItem("GONE_URL", kind: .variable)
        _ = try #require(RemoteFx.detect(Fx.snapshot(items: [row])).only)
        // markItemUnsynced
        row.syncedName = nil
        row.syncedFingerprint = nil
        row.hasSyncedValue = false
        #expect(ChangeSetBuilder.build(Fx.snapshot(items: [row])).changes.map(Describe.change) == ["set_variable repo GONE_URL new added"])
    }

    // MARK: - Environments

    @Test func environmentAddedBothResolutions() throws {
        let drift = try #require(RemoteFx.detect(Fx.snapshot(), environments: [
            try RemoteFx.environment("preview", id: 42, policy: .protected, listing: RemoteFx.scope(
                secrets: [RemoteFx.secret("B_SECRET")],
                variables: [RemoteFx.variable("A_VAR", value: "x")]
            )),
        ]).only)
        #expect(drift.kind == .environmentAdded)
        #expect(!drift.isConflict)
        #expect(drift.subject == .environment(DriftEnvironmentSubjectModel(
            key: .environment(named: "preview"),
            name: "preview",
            environmentID: nil,
            githubID: 42,
            remotePolicy: .protected,
            remoteItemNames: ["A_VAR", "B_SECRET"]
        )))
        #expect(drift.keepLocal.effects == [.createEnvironmentTombstone(name: "preview", githubID: 42)])
        #expect(drift.acceptGitHub.effects == [.importEnvironment(name: "preview", githubID: 42, policy: .protected)])
    }

    @Test func environmentAddedOverANeverSyncedEnvironmentIsAConflict() throws {
        let local = Fx.env("Preview")
        let drift = try #require(RemoteFx.detect(Fx.snapshot(environments: [local]), environments: [try RemoteFx.environment("preview", id: 42)]).only)
        #expect(drift.isConflict)
        #expect(drift.keepLocal.effects == [
            .adoptRemoteEnvironment(environmentID: local.id, remoteName: "preview", githubID: 42, remotePolicy: .all, adoptPolicy: false),
        ])
        #expect(drift.acceptGitHub.effects == [
            .adoptRemoteEnvironment(environmentID: local.id, remoteName: "preview", githubID: 42, remotePolicy: .all, adoptPolicy: true),
        ])
    }

    @Test func environmentAddedAtAPendingRenameTargetIsUnresolvable() throws {
        let renamed = Fx.env("stage", synced: "staging")
        let drifts = RemoteFx.detect(Fx.snapshot(environments: [renamed]), environments: [
            try RemoteFx.environment("staging", id: 1),
            try RemoteFx.environment("stage", id: 2),
        ])
        let drift = try #require(drifts.only)
        #expect(drift.kind == .environmentAdded)
        #expect(drift.isConflict)
        #expect(drift.keepLocal == .unavailable(.keepLocal, .conflictsWithPendingRename))
        #expect(drift.acceptGitHub == .unavailable(.acceptGitHub, .conflictsWithPendingRename))
    }

    @Test func environmentDeletedBothResolutionsCoverItsItems() throws {
        let qa = Fx.syncedEnv("qa")
        let local = Fx.snapshot(environments: [qa], items: [Fx.syncedItem("QA_TOKEN", env: qa)])
        let drift = try #require(RemoteFx.detect(local).only)
        #expect(drift.kind == .environmentDeleted)
        #expect(!drift.isConflict)
        #expect(drift.keepLocal.effects == [.markEnvironmentUnsynced(environmentID: qa.id)])
        #expect(drift.acceptGitHub.effects == [.deleteLocalEnvironment(environmentID: qa.id)])
    }

    @Test func environmentDeletedWithPendingItemsIsAConflict() throws {
        let qa = Fx.syncedEnv("qa")
        let local = Fx.snapshot(environments: [qa], items: [Fx.item("QA_NEW", env: qa)])
        #expect(try #require(RemoteFx.detect(local).only).isConflict)
    }

    @Test func environmentPolicyModifiedBothResolutions() throws {
        let production = Fx.syncedEnv("production")
        let drift = try #require(RemoteFx.detect(Fx.snapshot(environments: [production]), environments: [
            try RemoteFx.environment("production", id: 1, policy: .custom),
        ]).only)
        #expect(drift.kind == .environmentPolicyModified)
        #expect(!drift.isConflict)
        #expect(drift.keepLocal.effects == [.rebaseEnvironmentPolicy(environmentID: production.id, remotePolicy: .custom)])
        #expect(drift.acceptGitHub.effects == [.adoptRemoteEnvironmentPolicy(environmentID: production.id, remotePolicy: .custom)])
    }

    @Test func environmentTombstoneStillListedIsNoDrift() throws {
        let qa = Fx.env("qa", synced: "qa", deleted: true)
        let local = Fx.snapshot(environments: [qa], items: [Fx.syncedItem("QA_TOKEN", env: qa)])
        #expect(RemoteFx.detect(local, environments: [
            try RemoteFx.environment("qa", id: 3, listing: RemoteFx.scope(secrets: [RemoteFx.secret("OTHER")])),
        ]).isEmpty)
    }

    @Test func caseOnlyRenamedEnvironmentMatchesBySyncedName() throws {
        let production = Fx.env("Production", synced: "production")
        let row = Fx.syncedItem("URL", kind: .variable, env: production, value: "a")
        let drift = try #require(RemoteFx.detect(Fx.snapshot(environments: [production], items: [row]), environments: [
            try RemoteFx.environment("production", id: 1, listing: RemoteFx.scope(variables: [RemoteFx.variable("URL", value: "b")])),
        ]).only)
        #expect(drift.kind == .variableModified)
    }

    @Test func invalidRemoteEnvironmentNamesAreIgnored() throws {
        let local = Fx.snapshot()
        let remote = RemoteFx.snapshot(local, environments: [try RemoteFx.environment("..", id: 9)])
        #expect(remote.environments.isEmpty)
        #expect(remote.ignoredEnvironmentNames == [".."])
    }

    // MARK: - Lists over 100 items (multi-page)

    @Test func variableChangePastTheFirstPageIsFound() throws {
        let count = 150
        let changedIndex = 120
        let rows = (0..<count).map { index in
            Fx.syncedItem(Self.variableName(index), kind: .variable, value: "value-\(index)")
        }
        // gh follows every page; the decoded list is what `gh variable list --json` prints.
        let entries = (0..<count).map { index in
            [
                "name": Self.variableName(index),
                "value": index == changedIndex ? "changed" : "value-\(index)",
                "updatedAt": "2026-10-01T10:00:00Z",
                "createdAt": "2026-09-01T10:00:00Z",
            ]
        }
        let json = try JSONSerialization.data(withJSONObject: entries)
        let listings = try GHVariablesCommands.decodeList(GHCommandOutput(operation: .variableList, stdout: SecretBytes(json)))
        #expect(listings.count == count)

        var calls = 0
        let local = Fx.snapshot(items: rows)
        let remote = RemoteSnapshotModel(local: local, repository: RemoteFx.scope(variables: listings), environments: []) { value, row in
            calls += 1
            return Fx.fingerprint(value, row)
        }
        #expect(calls == count)
        let drift = try #require(DriftDetector.detect(local: local, remote: remote).only)
        #expect(drift.kind == .variableModified)
        guard case .item(let subject) = drift.subject else {
            Issue.record("expected an item")
            return
        }
        #expect(subject.name == Self.variableName(changedIndex))
        #expect(subject.itemID == rows[changedIndex].id)
    }

    @Test func secretChangePastTheFirstPageIsFound() throws {
        let count = 130
        let changedIndex = 101
        let rows = (0..<count).map { Fx.syncedItem("FXV_FIXTURE_SECRET_\($0)", remoteUpdatedAt: RemoteFx.monday) }
        let listed = (0..<count).map {
            RemoteFx.secret("FXV_FIXTURE_SECRET_\($0)", updatedAt: $0 == changedIndex ? RemoteFx.tuesday : RemoteFx.monday)
        }
        let drifts = RemoteFx.detect(Fx.snapshot(items: rows), repository: RemoteFx.scope(secrets: listed))
        let drift = try #require(drifts.only)
        #expect(drift.subject.target == .item(RemoteItemKeyModel(scope: .repository, kind: .secret, name: "FXV_FIXTURE_SECRET_101")))
    }

    // MARK: - Pending verification skip

    @Test func pendingRowsAreSkippedAfterThePass() {
        // The pass resolved the first row (now verified) and left the others pending.
        let resolved = Fx.syncedItem("RESOLVED", remoteUpdatedAt: RemoteFx.monday)
        let stillPending = Fx.syncedItem("STILL_PENDING", remoteUpdatedAt: RemoteFx.monday, verify: .pending)
        let pendingMissing = Fx.syncedItem("PENDING_MISSING", kind: .variable, verify: .pending)
        var pendingNew = Fx.item("PENDING_NEW", kind: .variable)
        pendingNew.verifyState = .pending
        let drifts = RemoteFx.detect(Fx.snapshot(items: [resolved, stillPending, pendingMissing, pendingNew]), repository: RemoteFx.scope(
            secrets: [
                RemoteFx.secret("RESOLVED", updatedAt: RemoteFx.tuesday),
                RemoteFx.secret("STILL_PENDING", updatedAt: RemoteFx.tuesday),
            ],
            variables: [RemoteFx.variable("PENDING_NEW", value: "other")]
        ))
        #expect(drifts.map(\.subject.target) == [.item(RemoteItemKeyModel(scope: .repository, kind: .secret, name: "RESOLVED"))])
    }

    // MARK: - Deletion suppression (journal)

    @Test func recentlyDeletedNamesAreNotReportedAsAdded() throws {
        let local = Fx.snapshot()
        let journalKeys = [
            RemoteItemKeyModel(scope: .repository, kind: .secret, name: "JUST_DELETED").journalKey,
            RemoteItemKeyModel(scope: .environment(named: "old"), kind: .variable, name: "X").journalKey,
            "env|old",
            "repo",
            "garbage",
        ]
        let suppression = DriftSuppressionModel(journalTargetKeys: journalKeys)
        #expect(suppression.deletedItems.count == 2)
        #expect(suppression.deletedEnvironments == [.environment(named: "OLD")])
        let drifts = RemoteFx.detect(
            local,
            repository: RemoteFx.scope(secrets: [RemoteFx.secret("JUST_DELETED"), RemoteFx.secret("REALLY_NEW")]),
            environments: [try RemoteFx.environment("old", id: 4)],
            suppression: suppression
        )
        #expect(drifts.map(\.subject.target) == [.item(RemoteItemKeyModel(scope: .repository, kind: .secret, name: "REALLY_NEW"))])
    }

    @Test func suppressionDoesNotHideAConflictWithALocalRow() throws {
        let row = Fx.item("JUST_DELETED")
        let suppression = DriftSuppressionModel(deletedItems: [RemoteItemKeyModel(scope: .repository, kind: .secret, name: "JUST_DELETED")])
        let drifts = RemoteFx.detect(Fx.snapshot(items: [row]), repository: RemoteFx.scope(secrets: [RemoteFx.secret("JUST_DELETED")]), suppression: suppression)
        #expect(try #require(drifts.only).isConflict)
    }

    // MARK: - Scope coverage

    @Test func unlistedScopesProduceNoItemFindings() throws {
        let production = Fx.syncedEnv("production")
        let local = Fx.snapshot(environments: [production], items: [Fx.syncedItem("A", env: production), Fx.syncedItem("B")])
        let drifts = RemoteFx.detect(local, repository: nil, environments: [try RemoteFx.environment("production", id: 1, listing: nil)])
        #expect(drifts.isEmpty)
    }

    @Test func repositoryNotOnGitHubHasNoDrift() {
        let local = Fx.snapshot(onGitHub: false, items: [Fx.syncedItem("A")])
        #expect(RemoteFx.detect(local).isEmpty)
    }

    @Test func fingerprintsAreComputedOnlyForCandidateRows() throws {
        let staging = Fx.env("stage", synced: "staging")
        let renamedVariable = Fx.item("NEW_URL", kind: .variable, env: staging, synced: "OLD_URL", syncedValue: "v1")
        let unrelated = Fx.syncedItem("OTHER", kind: .variable, env: staging)
        let repoLevel = Fx.syncedItem("OLD_URL", kind: .variable)
        let local = Fx.snapshot(environments: [staging], items: [renamedVariable, unrelated, repoLevel])
        let remote = RemoteFx.snapshot(local, repository: nil, environments: [
            try RemoteFx.environment("staging", id: 1, listing: RemoteFx.scope(variables: [
                RemoteFx.variable("OLD_URL", value: "a"),
                RemoteFx.variable("NEW_URL", value: "b"),
            ])),
        ])
        let listing = try #require(remote.listing(.environment(named: "Staging")))
        #expect(listing.variable(nameKey: "OLD_URL")?.fingerprints == [renamedVariable.id: Fx.fp("a", row: renamedVariable.id)])
        #expect(listing.variable(nameKey: "NEW_URL")?.fingerprints == [renamedVariable.id: Fx.fp("b", row: renamedVariable.id)])
    }

    @Test func driftIDsAreUniqueAndOrdered() throws {
        let production = Fx.syncedEnv("production")
        let qa = Fx.syncedEnv("qa")
        let local = Fx.snapshot(environments: [production, qa], items: [
            Fx.syncedItem("GONE"),
            Fx.syncedItem("URL", kind: .variable, env: production, value: "a"),
        ])
        let drifts = RemoteFx.detect(local, repository: RemoteFx.scope(secrets: [RemoteFx.secret("ADDED")]), environments: [
            try RemoteFx.environment("production", id: 1, policy: .protected, listing: RemoteFx.scope(variables: [RemoteFx.variable("URL", value: "b")])),
            try RemoteFx.environment("preview", id: 2),
        ])
        #expect(Set(drifts.map(\.id)).count == drifts.count)
        #expect(Set(drifts.map(\.kind)) == [.remoteAdded, .remoteDeleted, .variableModified, .environmentPolicyModified, .environmentAdded, .environmentDeleted])
        #expect(drifts.map(\.subject.target) == drifts.map(\.subject.target).sorted())
    }

    private static func variableName(_ index: Int) -> String {
        "FXV_FIXTURE_VAR_\(index)"
    }
}

private extension Array {
    /// The single element, or nil when there are zero or several.
    var only: Element? {
        count == 1 ? first : nil
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
