import EnvTools
import Foundation
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// The stage Overview and the `fxvault.yml` check (v0.8.0, tasks/todo.md R8, R9): columns, cells,
/// cycles, Differs and Blocked from real values, Missing and Extra from a manifest, the draft
/// manifest, and the stage list.
@Suite("StageOverview")
struct StageOverviewTests {
    static let manifestText = """
        stages: [production, staging]
        targets:
          ci:  { provider: github-actions }
          kv:  { provider: azure-keyvault, vault: { production: kv-sample-prod, staging: kv-sample-stg } }
          web: { provider: vercel, project: sample-web }
          api: { provider: supabase, project: abcdefghijklmnopqrst }
        vars:
          DATABASE_URL:            { secret: true, to: [kv] }
          RESEND_API_KEY:          { secret: true, to: [kv] }
          NEXT_PUBLIC_STRIPE_KEY:  { public: true, to: [web] }
          VERCEL_TOKEN:            { secret: true, to: [ci] }
          AZURE_CLIENT_ID:         { to: [ci] }
        """

    struct Fixture {
        let harness: ConfigHarness
        let destinations: DestinationRepository
        let overview: StageOverviewRepository
        let repo: RepoModel

        static func make() async throws -> Fixture {
            let harness = try await ConfigHarness.make()
            let repo = try harness.seedRepository()
            return Fixture(
                harness: harness,
                destinations: DestinationRepository(session: harness.session, clock: harness.clock),
                overview: StageOverviewRepository(session: harness.session, schedulers: nil),
                repo: repo
            )
        }

        func manifest() throws -> ManifestModel {
            let result = ManifestParser.parse(StageOverviewTests.manifestText)
            #expect(result.issues.isEmpty, "\(result.issues)")
            return try #require(result.manifest)
        }

        @discardableResult
        func vault(_ name: String = "kv-sample-prod", stage: String? = "production") throws -> DestinationID {
            try destinations.createDestination(repositoryID: repo.id, target: .azureKeyVault(vaultName: name, tenantID: nil), stage: stage, connectionID: nil)
        }

        @discardableResult
        func web(stage: String = "production") throws -> DestinationID {
            let connection = try destinations.addConnection(provider: .vercel, label: "Vercel \(stage)", token: SecretBytes(utf8: "t"), accountHint: nil)
            return try destinations.createDestination(
                repositoryID: repo.id,
                target: .vercel(projectID: "prj_sample", projectName: "sample-web", teamID: nil, environment: .production),
                stage: stage,
                connectionID: connection
            )
        }

        @discardableResult
        func add(_ destination: DestinationID, _ name: String, kind: ConfigKind = .secret, value: String) throws -> ConfigItemID {
            try destinations.addItem(destinationID: destination, kind: kind, name: name, value: SecretBytes(utf8: value)).itemID
        }

        func markSynced(_ destination: DestinationID) throws {
            let store = DestinationStore(database: harness.database)
            try harness.database.write { tx in
                for var row in try store.fetchItemRecords(destinationID: destination, in: tx) {
                    row.syncedName = row.name
                    row.syncedKind = row.kind
                    row.syncedFingerprint = row.valueFingerprint
                    try store.updateItem(row, in: tx)
                }
            }
        }

        func row(_ model: StageOverviewModel, _ name: String) throws -> StageOverviewRowModel {
            try #require(model.rows.first { $0.name == name })
        }
    }

    @Test func columnsAreGitHubThenTheStagesDestinations() async throws {
        let fixture = try await Fixture.make()
        let production = try fixture.vault()
        try fixture.vault("kv-sample-stg", stage: "staging")
        let web = try fixture.web()
        let model = try fixture.overview.overview(repositoryID: fixture.repo.id, stage: "Production", manifest: nil)
        #expect(model.columns.map(\.id) == ["github", production.uuidString, web.uuidString])
        #expect(!model.usesManifest)
        #expect(model.rows.isEmpty)
    }

    @Test func cellsFollowSyncStateAndInferCycles() async throws {
        let fixture = try await Fixture.make()
        let vault = try fixture.vault()
        let web = try fixture.web()
        try fixture.harness.add(fixture.repo, "VERCEL_TOKEN", value: "vercel-token-a")
        try fixture.add(vault, "DATABASE_URL", value: "postgres://db.example.invalid/app")
        try fixture.add(vault, "OLD_KEY", value: "old")
        try fixture.markSynced(vault)
        try fixture.add(vault, "NEW_KEY", value: "new")
        let gone = try #require(try fixture.destinations.items(destinationID: vault).first { $0.name == "OLD_KEY" })
        try fixture.destinations.deleteItems([gone.id])
        try fixture.add(web, "NEXT_PUBLIC_API_URL", kind: .variable, value: "https://api.example.invalid")

        let model = try fixture.overview.overview(repositoryID: fixture.repo.id, stage: "production", manifest: nil)
        #expect(try fixture.row(model, "DATABASE_URL").cells == [.notUsed, .synced, .notUsed])
        #expect(try fixture.row(model, "NEW_KEY").cells == [.notUsed, .willPush, .notUsed])
        #expect(try fixture.row(model, "OLD_KEY").cells == [.notUsed, .willDelete, .notUsed])
        #expect(try fixture.row(model, "VERCEL_TOKEN").cells == [.willPush, .notUsed, .notUsed])
        #expect(try fixture.row(model, "VERCEL_TOKEN").cycle == .build)
        #expect(try fixture.row(model, "DATABASE_URL").cycle == .runtime)
        #expect(try fixture.row(model, "NEXT_PUBLIC_API_URL").cycle == .publicValue)
        // Runtime first, then public, then build.
        #expect(model.rows.map(\.cycle) == model.rows.map(\.cycle).sorted())
    }

    @Test func differsComparesValuesAcrossColumnsAndBlockedChecksPublicValues() async throws {
        let fixture = try await Fixture.make()
        let vault = try fixture.vault()
        let web = try fixture.web()
        try fixture.add(vault, "STRIPE_SECRET_KEY", value: "value-a")
        try fixture.add(web, "STRIPE_SECRET_KEY", value: "value-b")
        try fixture.add(vault, "SAME_KEY", value: "same")
        try fixture.add(web, "SAME_KEY", value: "same")
        try fixture.markSynced(vault)
        try fixture.markSynced(web)
        let blocked = try fixture.add(web, "NEXT_PUBLIC_STRIPE_KEY", kind: .variable, value: "sk_live_" + String(repeating: "a", count: 24))
        try fixture.add(web, "NEXT_PUBLIC_SUPABASE_ANON_KEY", kind: .variable, value: ConfigFixture.sampleJWT)

        var model = try fixture.overview.overview(repositoryID: fixture.repo.id, stage: "production", manifest: nil)
        #expect(try fixture.row(model, "STRIPE_SECRET_KEY").cells == [.notUsed, .differs, .differs])
        #expect(try fixture.row(model, "SAME_KEY").cells == [.notUsed, .synced, .synced])
        #expect(try fixture.row(model, "NEXT_PUBLIC_STRIPE_KEY").cells == [.notUsed, .notUsed, .blocked])
        // A JWT under a public prefix only warns at Sync time: not blocked here.
        #expect(try fixture.row(model, "NEXT_PUBLIC_SUPABASE_ANON_KEY").cells == [.notUsed, .notUsed, .willPush])

        try fixture.destinations.setPublicAllowed(blocked, allowed: true)
        model = try fixture.overview.overview(repositoryID: fixture.repo.id, stage: "production", manifest: nil)
        #expect(try fixture.row(model, "NEXT_PUBLIC_STRIPE_KEY").cells == [.notUsed, .notUsed, .willPush])
    }

    @Test func theManifestAddsMissingExtraAndDestinationFindings() async throws {
        let fixture = try await Fixture.make()
        let vault = try fixture.vault()
        try fixture.web()
        try fixture.harness.add(fixture.repo, "VERCEL_TOKEN", value: "vercel-token-a")
        try fixture.harness.add(fixture.repo, "LEGACY_API_KEY", value: "legacy")
        try fixture.add(vault, "DATABASE_URL", value: "postgres://db.example.invalid/app")
        try fixture.markSynced(vault)
        let manifest = try fixture.manifest()

        let model = try fixture.overview.overview(repositoryID: fixture.repo.id, stage: "production", manifest: manifest)
        #expect(model.usesManifest)
        #expect(try fixture.row(model, "DATABASE_URL").cells == [.notUsed, .synced, .notUsed])
        #expect(try fixture.row(model, "RESEND_API_KEY").cells == [.notUsed, .missing, .notUsed])
        #expect(try fixture.row(model, "AZURE_CLIENT_ID").cells == [.missing, .notUsed, .notUsed])
        #expect(try fixture.row(model, "LEGACY_API_KEY").cells == [.extra, .notUsed, .notUsed])
        #expect(try fixture.row(model, "NEXT_PUBLIC_STRIPE_KEY").cells == [.notUsed, .notUsed, .missing])
        #expect(try fixture.row(model, "NEXT_PUBLIC_STRIPE_KEY").cycle == .publicValue)
        #expect(try fixture.row(model, "VERCEL_TOKEN").cycle == .build)
        #expect(model.findings.contains(.missing(name: "RESEND_API_KEY", column: vault.uuidString)))
        #expect(model.findings.contains(.extra(name: "LEGACY_API_KEY", column: "github")))
        // The manifest's Supabase target has no destination in the repository.
        #expect(model.findings.contains(.destinationNotAdded(target: "api", location: .supabase(projectRef: "abcdefghijklmnopqrst"))))

        // A stage the manifest does not declare gets no manifest checks.
        let other = try fixture.overview.overview(repositoryID: fixture.repo.id, stage: "qa", manifest: manifest)
        #expect(!other.usesManifest)
    }

    @Test func secretsInTheManifestThatAreVariablesAreReported() async throws {
        let fixture = try await Fixture.make()
        try fixture.harness.add(fixture.repo, "VERCEL_TOKEN", kind: .variable, value: "plain")
        let model = try fixture.overview.overview(repositoryID: fixture.repo.id, stage: "production", manifest: try fixture.manifest())
        #expect(model.findings.contains(.kindMismatch(name: "VERCEL_TOKEN", column: "github")))
    }

    @Test func stagesComeFromTheManifestDestinationsAndEnvironments() async throws {
        let fixture = try await Fixture.make()
        try fixture.vault("kv-sample-qa", stage: "qa")
        try fixture.harness.config.createEnvironment(in: fixture.repo.id, name: "preview")
        #expect(try fixture.overview.stages(repositoryID: fixture.repo.id, manifest: nil) == ["qa", "preview"])
        #expect(try fixture.overview.stages(repositoryID: fixture.repo.id, manifest: try fixture.manifest()) == ["production", "staging", "qa", "preview"])
    }

    @Test func theDraftManifestDescribesTheRepositoryAndParsesBack() async throws {
        let fixture = try await Fixture.make()
        let production = try fixture.vault()
        let staging = try fixture.vault("kv-sample-stg", stage: "staging")
        let web = try fixture.web()
        try fixture.harness.add(fixture.repo, "VERCEL_TOKEN", value: "vercel-token-a")
        try fixture.add(production, "DATABASE_URL", value: "a")
        try fixture.add(staging, "DATABASE_URL", value: "b")
        try fixture.add(production, "OPENAI_API_KEY", value: "c")
        try fixture.add(web, "NEXT_PUBLIC_API_URL", kind: .variable, value: "https://api.example.invalid")

        let draft = try fixture.overview.draftManifest(repositoryID: fixture.repo.id)
        #expect(draft.stages == ["production", "staging"])
        #expect(draft.targets.map(\.name) == ["ci", "kv", "web"])
        #expect(draft.location(of: "kv", at: "staging") == .keyVault(vaultName: "kv-sample-stg"))
        let byName = Dictionary(uniqueKeysWithValues: draft.vars.map { ($0.name, $0) })
        #expect(byName["DATABASE_URL"]?.targets == ["kv"])
        #expect(byName["DATABASE_URL"]?.stages == nil)
        #expect(byName["OPENAI_API_KEY"]?.stages == ["production"])
        #expect(byName["NEXT_PUBLIC_API_URL"]?.kind == .publicVariable)
        #expect(byName["VERCEL_TOKEN"]?.kind == .secret)

        let parsed = ManifestParser.parse(ManifestSerializer.render(draft))
        #expect(parsed.issues.isEmpty, "\(parsed.issues)")
        #expect(parsed.manifest == draft)
    }
}
