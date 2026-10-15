import Foundation
import Testing
import SyncEngine
import VaultCore

/// One row of the §7.1 change-derivation table.
struct DiffCase: Sendable, CustomTestStringConvertible {
    let name: String
    let snapshot: RepoSnapshotModel
    /// Executable changes (``Describe/change(_:)``), any order.
    let changes: [String]
    /// Blocked changes (``Describe/blocked(_:)``), any order.
    let blocked: [String]
    let pending: Int

    init(_ name: String, _ snapshot: RepoSnapshotModel, changes: [String], blocked: [String] = [], pending: Int) {
        self.name = name
        self.snapshot = snapshot
        self.changes = changes
        self.blocked = blocked
        self.pending = pending
    }

    var testDescription: String { name }
}

@Suite("SyncDiffTests")
struct SyncDiffTests {
    // MARK: - Table

    static let cases: [DiffCase] = repositoryCases + environmentCases + itemCases + coalescedCases

    static let repositoryCases: [DiffCase] = [
        DiffCase("synced repo with nothing pending", Fx.snapshot(items: [Fx.syncedItem("API_TOKEN")]), changes: [], pending: 0),
        DiffCase("repo without github_id is created", Fx.snapshot(onGitHub: false), changes: ["create_repository"], pending: 1),
        {
            let production = Fx.env("production")
            return DiffCase(
                "new repo with a new environment and items",
                Fx.snapshot(
                    onGitHub: false,
                    environments: [production],
                    items: [Fx.item("SENTRY_DSN"), Fx.item("API_URL", kind: .variable, env: production)]
                ),
                changes: [
                    "create_repository",
                    "upsert_environment production new all",
                    "set_secret repo SENTRY_DSN new added",
                    "set_variable env:production API_URL new added",
                ],
                pending: 4
            )
        }(),
        DiffCase(
            "new repo with a value-missing secret blocks only that secret",
            Fx.snapshot(onGitHub: false, items: [Fx.item("DB_PASSWORD", value: nil)]),
            changes: ["create_repository"],
            blocked: ["set_secret repo DB_PASSWORD new added ! valueMissing"],
            pending: 1
        ),
    ]

    static let environmentCases: [DiffCase] = [
        DiffCase("new environment, policy all", Fx.snapshot(environments: [Fx.env("staging")]), changes: ["upsert_environment staging new all"], pending: 1),
        {
            let id = EnvironmentID()
            let policy = DeploymentBranchPolicyModel.custom([Fx.pattern("release/*", env: id), Fx.pattern("main", env: id)])
            return DiffCase(
                "new custom environment counts its patterns with it",
                Fx.snapshot(environments: [Fx.env("production", policy: policy, id: id)]),
                changes: ["upsert_environment production new custom", "reconcile production +[main,release/*] -[]"],
                pending: 1
            )
        }(),
        DiffCase(
            "policy change all → protected",
            Fx.snapshot(environments: [Fx.env("production", synced: "production", policy: .protectedBranches, syncedPolicy: .all)]),
            changes: ["upsert_environment production update protected"],
            pending: 1
        ),
        {
            let id = EnvironmentID()
            let policy = DeploymentBranchPolicyModel.custom([Fx.pattern("main", env: id, synced: true), Fx.pattern("release/*", env: id)])
            return DiffCase(
                "unsynced pattern on a synced custom environment",
                Fx.snapshot(environments: [Fx.syncedEnv("production", policy: policy, id: id)]),
                changes: ["reconcile production +[main,release/*] -[]"],
                pending: 1
            )
        }(),
        {
            let id = EnvironmentID()
            let policy = DeploymentBranchPolicyModel.custom([
                Fx.pattern("main", env: id, synced: true),
                Fx.pattern("old/*", env: id, synced: true, deleted: true),
            ])
            return DiffCase(
                "deleted synced pattern",
                Fx.snapshot(environments: [Fx.syncedEnv("production", policy: policy, id: id)]),
                changes: ["reconcile production +[main] -[old/*]"],
                pending: 1
            )
        }(),
        {
            let id = EnvironmentID()
            let policy = DeploymentBranchPolicyModel.custom([
                Fx.pattern("main", env: id, synced: true),
                Fx.pattern("never-pushed", env: id, deleted: true),
            ])
            return DiffCase(
                "synced custom patterns and an unsynced tombstone pattern: nothing",
                Fx.snapshot(environments: [Fx.syncedEnv("production", policy: policy, id: id)]),
                changes: [],
                pending: 0
            )
        }(),
        {
            let id = EnvironmentID()
            let environment = Fx.env("production", synced: "production", policy: .all, syncedPolicy: .custom, id: id)
            return DiffCase(
                "custom → all upserts without reconciling",
                Fx.snapshot(environments: [environment]),
                changes: ["upsert_environment production update all"],
                pending: 1
            )
        }(),
        {
            let qa = Fx.env("qa", synced: "qa", deleted: true)
            return DiffCase(
                "environment tombstone deletes it; its items are implied",
                Fx.snapshot(environments: [qa], items: [Fx.syncedItem("QA_TOKEN", env: qa), Fx.item("QA_NEW", env: qa)]),
                changes: ["delete_environment qa"],
                pending: 1
            )
        }(),
        DiffCase("never-synced tombstone environment: nothing", Fx.snapshot(environments: [Fx.env("tmp", deleted: true)]), changes: [], pending: 0),
        {
            let production = Fx.env("Production", synced: "production")
            return DiffCase(
                "case-only environment rename is local only; items use GitHub's name",
                Fx.snapshot(environments: [production], items: [Fx.item("NEW_KEY", env: production)]),
                changes: ["set_secret env:production NEW_KEY new added"],
                pending: 1
            )
        }(),
        {
            let stage = Fx.env("stage", synced: "staging")
            return DiffCase(
                "synced rename copies live items, not tombstones",
                Fx.snapshot(environments: [stage], items: [
                    Fx.syncedItem("DB_URL", kind: .variable, env: stage),
                    Fx.item("API_KEY", env: stage, value: "v2", synced: "API_KEY", syncedValue: "v1"),
                    Fx.item("OLD", env: stage, synced: "OLD", syncedValue: "v1", deleted: true),
                ]),
                changes: [
                    "rename_environment staging->stage",
                    "set_variable env:stage DB_URL new copy",
                    "set_secret env:stage API_KEY new copy",
                ],
                pending: 1
            )
        }(),
        {
            let stage = Fx.env("stage", synced: "staging")
            return DiffCase(
                "rename blocked while a secret is value-missing",
                Fx.snapshot(environments: [stage], items: [
                    Fx.syncedItem("DB_URL", kind: .variable, env: stage),
                    Fx.syncedItem("DB_PASSWORD", env: stage, value: nil),
                ]),
                changes: [],
                blocked: [
                    "rename_environment staging->stage ! renameNeedsValues[DB_PASSWORD]",
                    "set_variable env:stage DB_URL new copy ! dependsOn",
                    "set_secret env:stage DB_PASSWORD new copy ! valueMissing",
                ],
                pending: 0
            )
        }(),
        {
            let tombstone = Fx.env("qa", synced: "qa", deleted: true, githubID: 5)
            let recreated = Fx.env("QA")
            return DiffCase(
                "environment tombstone plus create with different case becomes an upsert",
                Fx.snapshot(environments: [tombstone, recreated], items: [
                    Fx.syncedItem("A_KEY", env: tombstone),
                    Fx.syncedItem("B_KEY", env: tombstone),
                    Fx.item("A_KEY", env: recreated),
                ]),
                changes: [
                    "upsert_environment qa update all",
                    "set_secret env:QA A_KEY update added",
                    "delete_secret env:qa B_KEY with-env",
                ],
                pending: 3
            )
        }(),
        {
            let oldProd = Fx.env("prod", synced: "prod", deleted: true, githubID: 5)
            let renamed = Fx.env("prod", synced: "staging", githubID: 6)
            return DiffCase(
                "rename into a tombstoned environment's name keeps it and cleans its items",
                Fx.snapshot(environments: [oldProd, renamed], items: [
                    Fx.syncedItem("X_KEY", env: oldProd),
                    Fx.syncedItem("Z_KEY", env: oldProd),
                    Fx.syncedItem("X_KEY", env: renamed),
                    Fx.syncedItem("Y_KEY", env: renamed),
                ]),
                changes: [
                    "rename_environment staging->prod",
                    "set_secret env:prod X_KEY update copy",
                    "set_secret env:prod Y_KEY new copy",
                    "delete_secret env:prod Z_KEY with-env",
                ],
                pending: 2
            )
        }(),
        {
            let staging = Fx.env("staging")
            return DiffCase(
                "new environment with a value-missing secret",
                Fx.snapshot(environments: [staging], items: [Fx.item("TOKEN", env: staging, value: nil), Fx.item("URL", kind: .variable, env: staging)]),
                changes: ["upsert_environment staging new all", "set_variable env:staging URL new added"],
                blocked: ["set_secret env:staging TOKEN new added ! valueMissing"],
                pending: 2
            )
        }(),
    ]

    static let itemCases: [DiffCase] = [
        DiffCase("new repository secret", Fx.snapshot(items: [Fx.item("SENTRY_DSN")]), changes: ["set_secret repo SENTRY_DSN new added"], pending: 1),
        {
            let production = Fx.syncedEnv("production")
            return DiffCase(
                "new environment variable",
                Fx.snapshot(environments: [production], items: [Fx.item("API_URL", kind: .variable, env: production)]),
                changes: ["set_variable env:production API_URL new added"],
                pending: 1
            )
        }(),
        DiffCase(
            "modified value",
            Fx.snapshot(items: [Fx.item("STRIPE_KEY", value: "v2", synced: "STRIPE_KEY", syncedValue: "v1")]),
            changes: ["set_secret repo STRIPE_KEY update modified"],
            pending: 1
        ),
        DiffCase(
            "edited back to the synced value: nothing",
            Fx.snapshot(items: [Fx.item("STRIPE_KEY", value: "v1", synced: "STRIPE_KEY", syncedValue: "v1")]),
            changes: [],
            pending: 0
        ),
        DiffCase(
            "force_push with an equal fingerprint",
            Fx.snapshot(items: [Fx.item("API_TOKEN", synced: "API_TOKEN", syncedValue: "v1", forcePush: true)]),
            changes: ["set_secret repo API_TOKEN update force"],
            pending: 1
        ),
        DiffCase(
            "force_push without a local value is blocked",
            Fx.snapshot(items: [Fx.item("API_TOKEN", value: nil, synced: "API_TOKEN", forcePush: true)]),
            changes: [],
            blocked: ["set_secret repo API_TOKEN update force ! valueMissing"],
            pending: 0
        ),
        DiffCase(
            "item tombstone",
            Fx.snapshot(items: [Fx.item("OLD_KEY", synced: "OLD_KEY", syncedValue: "v1", deleted: true)]),
            changes: ["delete_secret repo OLD_KEY deleted"],
            pending: 1
        ),
        DiffCase(
            "never-synced tombstone item: nothing",
            Fx.snapshot(items: [Fx.item("DRAFT", deleted: true)]),
            changes: [],
            pending: 0
        ),
        DiffCase(
            "item rename is a set plus a delete",
            Fx.snapshot(items: [Fx.item("NEW_NAME", synced: "OLD_NAME", syncedValue: "v1")]),
            changes: ["set_secret repo NEW_NAME new renamed<-OLD_NAME", "delete_secret repo OLD_NAME renamed->NEW_NAME"],
            pending: 2
        ),
        DiffCase(
            "item rename of a value-missing secret blocks both halves",
            Fx.snapshot(items: [Fx.item("NEW_NAME", value: nil, synced: "OLD_NAME")]),
            changes: [],
            blocked: [
                "set_secret repo NEW_NAME new renamed<-OLD_NAME ! valueMissing",
                "delete_secret repo OLD_NAME renamed->NEW_NAME ! dependsOn",
            ],
            pending: 0
        ),
        DiffCase(
            "new name-only secret (from a share) is blocked",
            Fx.snapshot(items: [Fx.item("DB_PASSWORD", value: nil)]),
            changes: [],
            blocked: ["set_secret repo DB_PASSWORD new added ! valueMissing"],
            pending: 0
        ),
        DiffCase(
            "synced value-missing secret without force_push: nothing",
            Fx.snapshot(items: [Fx.syncedItem("DB_PASSWORD", value: nil)]),
            changes: [],
            pending: 0
        ),
        DiffCase(
            "filled secret with no synced fingerprint is pushed",
            Fx.snapshot(items: [Fx.item("DB_PASSWORD", value: "filled", synced: "DB_PASSWORD")]),
            changes: ["set_secret repo DB_PASSWORD update modified"],
            pending: 1
        ),
        DiffCase(
            "same name as secret and variable are two keys",
            Fx.snapshot(items: [Fx.item("SHARED"), Fx.item("SHARED", kind: .variable)]),
            changes: ["set_secret repo SHARED new added", "set_variable repo SHARED new added"],
            pending: 2
        ),
        {
            let qa = Fx.env("qa", synced: "qa", deleted: true)
            return DiffCase(
                "pending items inside a deleted environment are not pushed",
                Fx.snapshot(environments: [qa], items: [Fx.item("MODIFIED", env: qa, value: "v2", synced: "MODIFIED", syncedValue: "v1")]),
                changes: ["delete_environment qa"],
                pending: 1
            )
        }(),
        {
            let production = Fx.syncedEnv("production")
            return DiffCase(
                "a variable and a secret pending in one scope",
                Fx.snapshot(environments: [production], items: [
                    Fx.item("URL", kind: .variable, env: production, value: "b", synced: "URL", syncedValue: "a"),
                    Fx.item("TOKEN", env: production, synced: "TOKEN", syncedValue: "v1", deleted: true),
                ]),
                changes: ["set_variable env:production URL update modified", "delete_secret env:production TOKEN deleted"],
                pending: 2
            )
        }(),
    ]

    static let coalescedCases: [DiffCase] = [
        DiffCase(
            "delete plus rename-into the deleted name",
            // The editor revives the tombstone instead (§7.1); normalization must still be safe
            // for rows that reach this state through old data.
            Fx.snapshot(items: [
                Fx.item("FOO", synced: "FOO", syncedValue: "v1", deleted: true),
                Fx.item("FOO", value: "v9", synced: "BAR", syncedValue: "v9"),
            ]),
            changes: ["set_secret repo FOO update renamed<-BAR", "delete_secret repo BAR renamed->FOO"],
            pending: 2
        ),
        DiffCase(
            "swap A↔B by renames is two updates",
            Fx.snapshot(items: [
                Fx.item("B_KEY", value: "a", synced: "A_KEY", syncedValue: "a"),
                Fx.item("A_KEY", value: "b", synced: "B_KEY", syncedValue: "b"),
            ]),
            changes: ["set_secret repo A_KEY update renamed<-B_KEY", "set_secret repo B_KEY update renamed<-A_KEY"],
            pending: 2
        ),
        DiffCase(
            "swap A↔B by values is two modifications",
            Fx.snapshot(items: [
                Fx.item("A_KEY", value: "b", synced: "A_KEY", syncedValue: "a"),
                Fx.item("B_KEY", value: "a", synced: "B_KEY", syncedValue: "b"),
            ]),
            changes: ["set_secret repo A_KEY update modified", "set_secret repo B_KEY update modified"],
            pending: 2
        ),
        {
            let staging = Fx.env("staging")
            let production = Fx.syncedEnv("production")
            return DiffCase(
                "M3 done-when: new env with 2+2 items, 1 edit, 1 delete",
                Fx.snapshot(environments: [staging, production], items: [
                    Fx.item("S_ONE", env: staging),
                    Fx.item("S_TWO", env: staging),
                    Fx.item("V_ONE", kind: .variable, env: staging),
                    Fx.item("V_TWO", kind: .variable, env: staging),
                    Fx.item("EDITED", env: production, value: "v2", synced: "EDITED", syncedValue: "v1"),
                    Fx.item("GONE", env: production, synced: "GONE", syncedValue: "v1", deleted: true),
                ]),
                changes: [
                    "upsert_environment staging new all",
                    "set_secret env:staging S_ONE new added",
                    "set_secret env:staging S_TWO new added",
                    "set_variable env:staging V_ONE new added",
                    "set_variable env:staging V_TWO new added",
                    "set_secret env:production EDITED update modified",
                    "delete_secret env:production GONE deleted",
                ],
                pending: 7
            )
        }(),
    ]

    // MARK: - Tests

    @Test("change derivation table", arguments: cases)
    func derivation(_ testCase: DiffCase) {
        let changeSet = ChangeSetBuilder.build(testCase.snapshot)
        #expect(changeSet.changes.map(Describe.change).sorted() == testCase.changes.sorted())
        #expect(changeSet.blocked.map(Describe.blocked).sorted() == testCase.blocked.sorted())
        #expect(changeSet.pendingCount == testCase.pending)
    }

    @Test("normalization invariant: no key both upserted and deleted", arguments: cases)
    func invariant(_ testCase: DiffCase) {
        let changeSet = ChangeSetBuilder.build(testCase.snapshot)
        let violations = ChangeSetNormalizer.invariantViolations(in: changeSet)
        #expect(violations.items.isEmpty)
        #expect(violations.environments.isEmpty)
        #expect(Set(changeSet.allChanges.map(\.id)).count == changeSet.allChanges.count)
    }

    @Test func tableHasAtLeastThirtyFiveCases() {
        #expect(Self.cases.count >= 35)
    }

    @Test func caseOnlyRenameIsANote() {
        let production = Fx.env("Production", synced: "production")
        let changeSet = ChangeSetBuilder.build(Fx.snapshot(environments: [production]))
        #expect(changeSet.isEmpty)
        #expect(changeSet.notes == [.caseOnlyEnvironmentRename(environmentID: production.id, syncedName: "production", name: "Production")])
    }

    @Test func canonicalOrder() {
        let staging = Fx.env("staging")
        let qa = Fx.env("qa", synced: "qa", deleted: true)
        let snapshot = Fx.snapshot(onGitHub: false, environments: [qa, staging], items: [
            Fx.item("GONE", synced: "GONE", syncedValue: "v1", deleted: true),
            Fx.item("A_SECRET", env: staging),
            Fx.item("A_VARIABLE", kind: .variable, env: staging),
            Fx.item("REPO_SECRET"),
        ])
        let order = ChangeSetBuilder.build(snapshot).changes.map(Describe.change)
        #expect(order == [
            "create_repository",
            "upsert_environment staging new all",
            "set_variable env:staging A_VARIABLE new added",
            "set_secret repo REPO_SECRET new added",
            "set_secret env:staging A_SECRET new added",
            "delete_secret repo GONE deleted",
            "delete_environment qa",
        ])
    }

    @Test func deletionCountForConfirmation() {
        let qa = Fx.env("qa", synced: "qa", deleted: true)
        let changeSet = ChangeSetBuilder.build(Fx.snapshot(environments: [qa], items: [
            Fx.item("GONE", synced: "GONE", syncedValue: "v1", deleted: true),
            Fx.item("NEW_NAME", synced: "OLD_NAME", syncedValue: "v1"),
        ]))
        #expect(changeSet.deletionCount == 3)
    }

    @Test func impliedItemsOfADeletedEnvironmentAreListed() throws {
        let qa = Fx.env("qa", synced: "qa", deleted: true, githubID: 9)
        let token = Fx.syncedItem("QA_TOKEN", env: qa)
        let changeSet = ChangeSetBuilder.build(Fx.snapshot(environments: [qa], items: [token, Fx.item("UNSYNCED", env: qa)]))
        let change = try #require(changeSet.changes.first)
        guard case .deleteEnvironment(let delete) = change.operation else {
            Issue.record("expected an environment delete")
            return
        }
        #expect(delete.githubID == 9)
        #expect(delete.impliedItems == [.init(itemID: token.id, kind: .secret, name: "QA_TOKEN")])
    }

    // MARK: - Blocking (D27)

    @Test func remoteChangedOnANewEnvironmentBlocksItsContents() throws {
        let staging = Fx.env("staging")
        let changeSet = ChangeSetBuilder.build(Fx.snapshot(environments: [staging], items: [
            Fx.item("TOKEN", env: staging),
            Fx.item("REPO_LEVEL"),
        ]))
        let upsert = try #require(changeSet.changes.first { $0.kind == .upsertEnvironment })
        let blocked = changeSet.blocking([upsert.id], reason: .remoteChanged)
        #expect(blocked.changes.map(Describe.change) == ["set_secret repo REPO_LEVEL new added"])
        #expect(blocked.blocked.map(Describe.blocked).sorted() == [
            "set_secret env:staging TOKEN new added ! dependsOn",
            "upsert_environment staging new all ! remoteChanged",
        ])
        #expect(blocked.pendingCount == 1)
    }

    @Test func remoteChangedOnARenameSourceBlocksTheNewName() throws {
        let changeSet = ChangeSetBuilder.build(Fx.snapshot(items: [Fx.item("NEW_NAME", synced: "OLD_NAME", syncedValue: "v1")]))
        let delete = try #require(changeSet.changes.first { $0.kind == .deleteSecret })
        let blocked = changeSet.blocking([delete.id], reason: .remoteChanged)
        #expect(blocked.changes.isEmpty)
        #expect(blocked.blocked.map(Describe.blocked).sorted() == [
            "delete_secret repo OLD_NAME renamed->NEW_NAME ! remoteChanged",
            "set_secret repo NEW_NAME new renamed<-OLD_NAME ! dependsOn",
        ])
    }

    @Test func blockingAFailedRepositoryCreateBlocksEverything() throws {
        let changeSet = ChangeSetBuilder.build(Fx.snapshot(onGitHub: false, items: [Fx.item("A_KEY")]))
        let create = try #require(changeSet.changes.first)
        let blocked = changeSet.blocking([create.id], reason: .remoteChanged)
        #expect(blocked.changes.isEmpty)
        #expect(blocked.blocked.count == 2)
    }

    @Test func blockingUnknownIDsChangesNothing() {
        let changeSet = ChangeSetBuilder.build(Fx.snapshot(items: [Fx.item("A_KEY")]))
        #expect(changeSet.blocking(["nope"], reason: .remoteChanged) == changeSet)
    }

    // MARK: - Normalizer on plain changes

    @Test func setPlusDeleteOnOneKeyBecomesAnUpdate() {
        let id = ConfigItemID()
        let set = ConfigChangeModel(repositoryID: Fx.repoID, operation: .setItem(ItemSetChangeModel(
            itemID: id, environmentID: nil, environmentName: nil, kind: .variable, name: "URL", isNew: true, reason: .added
        )))
        let delete = ConfigChangeModel(repositoryID: Fx.repoID, operation: .deleteItem(ItemDeleteChangeModel(
            itemID: ConfigItemID(), environmentID: nil, environmentName: nil, kind: .variable, name: "url", reason: .deleted
        )))
        let normalized = ChangeSetNormalizer.normalize([delete, set])
        #expect(normalized.map(Describe.change) == ["set_variable repo URL update added"])
    }

    @Test func environmentCreatePlusDeleteBecomesUpsertWithTheDeletedBase() {
        let environmentID = EnvironmentID()
        let create = ConfigChangeModel(repositoryID: Fx.repoID, operation: .upsertEnvironment(EnvironmentUpsertChangeModel(
            environmentID: environmentID, name: "PRODUCTION", policy: .protectedBranches, syncedPolicy: nil, isNew: true
        )))
        let delete = ConfigChangeModel(repositoryID: Fx.repoID, operation: .deleteEnvironment(EnvironmentDeleteChangeModel(
            environmentID: EnvironmentID(), name: "production", githubID: 3, syncedPolicy: .all, impliedItems: []
        )))
        let normalized = ChangeSetNormalizer.normalize([create, delete])
        #expect(normalized.count == 1)
        guard case .upsertEnvironment(let upsert) = normalized.first?.operation else {
            Issue.record("expected an upsert")
            return
        }
        #expect(!upsert.isNew)
        #expect(upsert.syncedPolicy == .all)
        #expect(upsert.name == "production")
        #expect(upsert.environmentID == environmentID)
    }

    @Test func journalKeysRoundTrip() throws {
        let keys = [
            RemoteItemKeyModel(scope: .repository, kind: .secret, name: "API_TOKEN"),
            RemoteItemKeyModel(scope: .environment(named: "Producción"), kind: .variable, name: "url"),
            RemoteItemKeyModel(scope: .environment(named: "a|b"), kind: .secret, name: "X"),
        ]
        for key in keys {
            #expect(RemoteItemKeyModel(journalKey: key.journalKey) == key)
        }
        #expect(RemoteItemKeyModel(journalKey: "env|qa") == nil)
        #expect(RemoteItemKeyModel(journalKey: "item|secret||repo") == nil)
        #expect(RemoteScopeKeyModel(environmentJournalKey: "env|qa") == .environment(named: "QA"))
        #expect(RemoteScopeKeyModel(environmentJournalKey: "repo") == nil)
        let change = try #require(ChangeSetBuilder.build(Fx.snapshot(items: [Fx.item("api_token")])).changes.first)
        #expect(change.target.journalKey == "item|secret|API_TOKEN|repo")
        #expect(change.id == "set_secret:item|secret|API_TOKEN|repo")
    }
}
