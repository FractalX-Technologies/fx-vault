import EnvTools
import Foundation
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// Copy All's text (1.0 D6c4, board Main2-Repository): a place's live items as `.env` text, one
/// section per kind, behind its own single-use authorization.
@Suite("Copy All text")
struct CopyAllTextTests {
    static func title(_ kind: ConfigKind, _ count: Int) -> String {
        "\(kind == .secret ? "Secrets" : "Variables") · \(count)"
    }

    static func clipboardAuthorization(_ harness: ConfigHarness) async throws -> EnvExportAuthorizationModel {
        try await ReauthGate(manager: harness.manager).authorizeEnvExport(
            .clipboard,
            with: .password(ConfigFixture.password),
            session: harness.session
        )
    }

    static func text(
        _ files: EnvFileRepository,
        _ place: CopyAllPlaceModel,
        _ authorization: EnvExportAuthorizationModel
    ) throws -> String? {
        let text = try files.copyAllText(of: place, authorization: authorization, sectionTitle: title)
        defer { text.wipe() }
        return text.utf8String()
    }

    /// Secrets first, then variables, names in order, a blank line between; a secret without a
    /// value is `KEY=`, a pending deletion is left out, and a secret and a variable may share a
    /// name (the `.env` file export keeps only the secret).
    @Test func aScopeIsItsSecretsThenItsVariables() async throws {
        let fixture = try await EnvFileTests.Fixture.make()
        defer { fixture.directory.remove() }
        let harness = fixture.harness
        let scope = ConfigScope.environment(fixture.staging)
        let old = try harness.add(fixture.repo, "OLD_KEY", value: ConfigFixture.valueC, scope: scope)
        try harness.markSynced(fixture.repo)
        try harness.config.deleteItems([old], repositoryID: fixture.repo.id)
        try harness.add(fixture.repo, "API_TOKEN", value: ConfigFixture.valueB, scope: scope)
        try harness.add(fixture.repo, "API_TOKEN", kind: .variable, value: "shared-name", scope: scope)
        try harness.add(fixture.repo, "MULTI_LINE", kind: .variable, value: "line one\nline two", scope: scope)
        try harness.store.insertItem(ConfigItemRecord(
            repositoryID: fixture.repo.id,
            scope: scope,
            kind: .secret,
            name: "IMPORTED",
            valueCiphertext: nil,
            valueFingerprint: nil,
            syncedName: "IMPORTED",
            createdAt: harness.clock.now,
            updatedAt: harness.clock.now
        ))

        let text = try Self.text(
            fixture.files,
            .place(.scope(repositoryID: fixture.repo.id, scope: scope)),
            try await Self.clipboardAuthorization(harness)
        )
        #expect(text == """
        # Secrets · 2
        API_TOKEN=value-b
        IMPORTED=

        # Variables · 2
        API_TOKEN=shared-name
        MULTI_LINE='line one
        line two'

        """)
    }

    /// A Key Vault holds secrets only: no Variables section.
    @Test func aKeyVaultHasOnlyItsSecretsSection() async throws {
        let fixture = try await EnvFileTests.Fixture.make()
        defer { fixture.directory.remove() }
        let harness = fixture.harness
        let destinations = DestinationRepository(session: harness.session, clock: harness.clock)
        let vault = try destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-shared", tenantID: nil),
            stage: nil
        )
        try destinations.addItem(destinationID: vault, kind: .secret, name: "DATABASE_URL", value: SecretBytes(utf8: ConfigFixture.valueA))

        let text = try Self.text(fixture.files, .place(.destination(vault)), try await Self.clipboardAuthorization(harness))
        #expect(text == "# Secrets · 1\nDATABASE_URL='\(ConfigFixture.valueA)'\n")
    }

    /// An organization's secrets imported from GitHub have no value until one is set.
    @Test func anOrganizationIsItsItemsWithoutValuesAsEmpty() async throws {
        let fixture = try await OrganizationItemRepositoryTests.Fixture.make()
        let harness = fixture.base.harness
        let stripe = try await fixture.item("STRIPE_KEY")
        _ = try fixture.items.setValue(stripe.id, value: fixture.value("FXV_FIXTURE_SECRET"))
        let files = EnvFileRepository(session: harness.session, gitignoreChecker: StubGitignoreChecker(), clock: harness.clock)

        let text = try #require(try Self.text(
            files,
            .organization(fixture.organization.id),
            try await Self.clipboardAuthorization(harness)
        ))
        #expect(text.hasPrefix("# Secrets · 2\nNPM_TOKEN=\nSTRIPE_KEY=FXV_FIXTURE_SECRET\n\n# Variables · 2\nFXV_FIXTURE_URL="))
        #expect(text.hasSuffix("\nREGION=eu-west\n"))
    }

    /// Each plaintext export needs its own check: a `.env` file authorization never copies, a
    /// clipboard one never writes a file, and neither is reused.
    @Test func copyAllNeedsAFreshClipboardAuthorization() async throws {
        let fixture = try await EnvFileTests.Fixture.make()
        defer { fixture.directory.remove() }
        try fixture.harness.add(fixture.repo, "TOKEN", value: ConfigFixture.valueB)
        let place = CopyAllPlaceModel.place(.scope(repositoryID: fixture.repo.id, scope: .repository))

        let fileAuthorization = try await fixture.authorize()
        #expect(fileAuthorization.purpose == .file)
        #expect(Self.envFileError { _ = try Self.text(fixture.files, place, fileAuthorization) } == .authorizationInvalid)

        let clipboard = try await Self.clipboardAuthorization(fixture.harness)
        #expect(clipboard.purpose == .clipboard)
        let fileWrite = Self.envFileError {
            _ = try fixture.files.export(
                repositoryID: fixture.repo.id,
                scope: .repository,
                to: fixture.directory.file("a.env"),
                authorization: clipboard
            )
        }
        #expect(fileWrite == .authorizationInvalid)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.file("a.env").path))

        let fresh = try await Self.clipboardAuthorization(fixture.harness)
        #expect(try Self.text(fixture.files, place, fresh) == "# Secrets · 1\nTOKEN=value-b\n")
        #expect(!fresh.isUsable)
        #expect(Self.envFileError { _ = try Self.text(fixture.files, place, fresh) } == .authorizationInvalid)

        // A lock in between invalidates it too.
        let stale = try await Self.clipboardAuthorization(fixture.harness)
        fixture.harness.manager.lock()
        try await fixture.harness.manager.unlock(password: ConfigFixture.password)
        #expect(Self.envFileError { _ = try Self.text(fixture.files, place, stale) } == .authorizationInvalid)
    }

    private static func envFileError(_ body: () throws -> Void) -> EnvFileError? {
        do {
            try body()
            return nil
        } catch let error as EnvFileError {
            return error
        } catch {
            Issue.record("Expected an EnvFileError, got \(error)")
            return nil
        }
    }
}
