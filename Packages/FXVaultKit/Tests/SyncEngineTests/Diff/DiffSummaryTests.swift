import Foundation
import Testing
import SyncEngine
import VaultCore

/// §7.2 summary: the model (names, counts, blocked, remote changed) and the plain-text layout
/// with an English vocabulary (the app supplies the localized one).
@Suite("SyncDiffTests.summary")
struct DiffSummaryTests {
    static let english = ChangeSummaryVocabulary(
        newRepository: { repository in
            var parts = ["new repository", repository.visibility == .public ? "public" : "private"]
            if repository.addsReadme { parts.append("README") }
            if let gitignore = repository.gitignoreTemplate { parts.append("\(gitignore) .gitignore") }
            if let license = repository.licenseTemplate { parts.append(license) }
            return "(" + parts.joined(separator: " · ") + ")"
        },
        scopeLabel: { scope in
            switch (scope.label, scope.environmentChange) {
            case (.environment(let name), .renamed(let from)?): "\(from) → \(name)"
            case (.environment(let name), _): name
            case (.repository, _): "Repository"
            }
        },
        scopeStatus: { scope in
            switch scope.environmentChange {
            case .renamed?: return "renamed (recreated on GitHub)"
            case .deleted?: return "deleted — contents fetched live at confirmation"
            default: break
            }
            let counts = [
                (scope.addedCount, "added"),
                (scope.renamedCount, "renamed"),
                (scope.modifiedCount, "modified"),
                (scope.deletedCount, "deleted"),
            ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
            if !counts.isEmpty { return counts.joined(separator: ", ") }
            return scope.environmentChange == .created ? "new environment" : "policy changed"
        },
        item: { item in
            let kind = "(\(item.kind.rawValue))"
            return switch item.change {
            case .added: "+ \(item.name) \(kind)"
            case .modified: "~ \(item.name) \(kind)"
            case .deleted: "- \(item.name) \(kind)"
            case .renamed(let from): "\(from) → \(item.name) \(kind)"
            }
        },
        policy: { policy in
            switch policy.kind {
            case .all: "policy: all branches"
            case .protected: "policy: protected branches"
            case .custom: "policy: custom (\(policy.patterns.joined(separator: ", ")))"
            }
        },
        blocked: { entry in
            let scope = switch entry.scope {
            case .repository: "Repository"
            case .environment(let name): name
            }
            return switch entry.reason {
            case .renameNeedsValues(let names): "Blocked: rename to \(scope) — values missing: \(names.joined(separator: ", "))"
            default: "Blocked: \(entry.name) in \(scope) — value missing locally"
            }
        },
        remoteChanged: { entries in
            let names = entries.map { entry in
                let scope = switch entry.scope {
                case .repository: "Repository"
                case .environment(let name): name
                }
                return "\(entry.name) (\(scope))"
            }
            return "Changed on GitHub since your last check: \(names.joined(separator: ", ")) — review before syncing"
        },
        writeBudget: { budget in
            "FX Vault write limit this hour: \(budget.used) of \(budget.limit) (other gh or GitHub activity also counts toward GitHub's limits)"
        }
    )

    /// The §7.2 example, rebuilt from rows.
    static func exampleChangeSet() throws -> ChangeSetModel {
        let productionID = EnvironmentID()
        let production = Fx.env(
            "production",
            synced: "production",
            policy: .custom([Fx.pattern("release/*", env: productionID)]),
            syncedPolicy: .all,
            id: productionID
        )
        let stage = Fx.env("stage", synced: "staging")
        let qa = Fx.env("qa", synced: "qa", deleted: true)
        let snapshot = Fx.snapshot(
            onGitHub: false,
            spec: RepoCreateSpecModel(autoInit: true, gitignoreTemplate: "Swift", licenseTemplate: "MIT", cloneAfter: true),
            environments: [production, stage, qa],
            items: [
                Fx.item("SENTRY_DSN", value: "s3cr3t-value"),
                Fx.item("API_URL", kind: .variable),
                Fx.item("STRIPE_KEY", value: "v2", synced: "STRIPE_KEY", syncedValue: "v1"),
                Fx.item("API_TOKEN", value: "v2", synced: "API_TOKEN", syncedValue: "v1"),
                Fx.item("P_ONE", env: production),
                Fx.item("P_TWO", env: production),
                Fx.item("P_THREE", kind: .variable, env: production),
                Fx.item("P_MOD", env: production, value: "v2", synced: "P_MOD", syncedValue: "v1"),
                Fx.item("P_GONE", env: production, synced: "P_GONE", syncedValue: "v1", deleted: true),
                Fx.item("DB_PASSWORD", env: production, value: nil),
                Fx.syncedItem("STAGE_URL", kind: .variable, env: stage),
                Fx.syncedItem("QA_TOKEN", env: qa),
            ]
        )
        let changeSet = ChangeSetBuilder.build(snapshot)
        let apiToken = try #require(changeSet.changes.first { $0.target.journalKey == "item|secret|API_TOKEN|repo" })
        return changeSet.blocking([apiToken.id], reason: .remoteChanged)
    }

    @Test func rendersTheSection72Layout() throws {
        let summary = ChangeSummaryBuilder.summarize([try Self.exampleChangeSet()], writeBudget: WriteBudgetModel(used: 412))
        let lines = ChangeSummaryRenderer.lines(summary, vocabulary: Self.english)
        #expect(lines == [
            "owner-a/api                                          (new repository · private · README · Swift .gitignore · MIT)",
            "  Repository        2 added, 1 modified              + API_URL (variable)  + SENTRY_DSN (secret)  ~ STRIPE_KEY (secret)",
            "  production        3 added, 1 modified, 1 deleted   policy: custom (release/*)  + P_ONE (secret)  + P_THREE (variable)  + P_TWO (secret)  ~ P_MOD (secret)  - P_GONE (secret)",
            "  qa                deleted — contents fetched live at confirmation",
            "  staging → stage   renamed (recreated on GitHub)",
            "Blocked: DB_PASSWORD in production — value missing locally",
            "Changed on GitHub since your last check: API_TOKEN (Repository) — review before syncing",
            "FX Vault write limit this hour: 412 of 450 (other gh or GitHub activity also counts toward GitHub's limits)",
        ])
        #expect(ChangeSummaryRenderer.render(summary, vocabulary: Self.english) == lines.joined(separator: "\n"))
    }

    @Test func summaryModelCountsAndNamesOnly() throws {
        let changeSet = try Self.exampleChangeSet()
        let repository = ChangeSummaryBuilder.summarize(changeSet)
        #expect(repository.fullName == "owner-a/api")
        #expect(repository.newRepository == NewRepositorySummaryModel(visibility: .private, addsReadme: true, gitignoreTemplate: "Swift", licenseTemplate: "MIT"))
        // create + Repository 3 + production (policy 1 + 5 items) + rename 1 + qa delete 1.
        #expect(repository.pendingCount == 12)
        #expect(repository.pendingCount == changeSet.pendingCount)
        #expect(repository.blocked == [BlockedSummaryModel(name: "DB_PASSWORD", kind: .secret, scope: .environment("production"), reason: .valueMissing)])
        #expect(repository.remoteChanged == [RemoteChangedSummaryModel(name: "API_TOKEN", kind: .secret, scope: .repository)])
        let production = try #require(repository.scopes.first { $0.label == .environment("production") })
        #expect((production.addedCount, production.modifiedCount, production.deletedCount) == (3, 1, 1))
        #expect(production.environmentChange == .policyChanged)
        #expect(production.policy == PolicySummaryModel(kind: .custom, patterns: ["release/*"]))

        let summary = ChangeSummaryModel(repositories: [repository])
        #expect(summary.pendingCount == 12)
        #expect(summary.blockedCount == 2)
        let text = ChangeSummaryRenderer.render(summary, vocabulary: Self.english)
        #expect(!text.contains("s3cr3t-value"))
        #expect(!text.contains("QA_TOKEN"))
        #expect(!text.contains("STAGE_URL"))
    }

    @Test func renamedItemsAndRenameBlockedByMissingValues() {
        let stage = Fx.env("stage", synced: "staging")
        let changeSet = ChangeSetBuilder.build(Fx.snapshot(environments: [stage], items: [
            Fx.item("NEW_NAME", synced: "OLD_NAME", syncedValue: "v1"),
            Fx.syncedItem("DB_PASSWORD", env: stage, value: nil),
        ]))
        let lines = ChangeSummaryRenderer.lines(ChangeSummaryBuilder.summarize([changeSet]), vocabulary: Self.english)
        #expect(lines == [
            "owner-a/api",
            "  Repository   1 renamed   OLD_NAME → NEW_NAME (secret)",
            "Blocked: rename to stage — values missing: DB_PASSWORD",
            "Blocked: DB_PASSWORD in stage — value missing locally",
        ])
    }

    @Test func newEnvironmentLineAndEmptySummary() {
        let staging = Fx.env("staging", policy: .protectedBranches)
        let changeSet = ChangeSetBuilder.build(Fx.snapshot(environments: [staging]))
        let summary = ChangeSummaryBuilder.summarize([changeSet])
        #expect(ChangeSummaryRenderer.lines(summary, vocabulary: Self.english) == [
            "owner-a/api",
            "  staging   new environment   policy: protected branches",
        ])
        let empty = ChangeSummaryBuilder.summarize([ChangeSetBuilder.build(Fx.snapshot())])
        #expect(empty.repositories.first?.scopes.isEmpty == true)
        #expect(empty.pendingCount == 0)
    }

    @Test func caseOnlyRenameNoteIsCarried() {
        let production = Fx.env("Production", synced: "production")
        let summary = ChangeSummaryBuilder.summarize(ChangeSetBuilder.build(Fx.snapshot(environments: [production])))
        #expect(summary.notes == [.caseOnlyEnvironmentRename(environmentID: production.id, syncedName: "production", name: "Production")])
        #expect(summary.scopes.isEmpty)
    }
}
