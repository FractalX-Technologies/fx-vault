import Foundation
import GRDB
import Testing
import VaultCore
@testable import VaultStore

/// §6 schema constraints: CHECKs, unique (fold-key) indexes, foreign keys and cascades.
@Suite("Schema constraints")
struct ConstraintTests {
    static let check = StoreError.constraintViolation(.check)
    static let unique = StoreError.constraintViolation(.unique)
    static let primaryKey = StoreError.constraintViolation(.primaryKey)
    static let foreignKey = StoreError.constraintViolation(.foreignKey)

    // MARK: - config_items

    @Test func itemNameMustBeUppercase() throws {
        let seeded = try SeededDatabase()
        #expect(throws: Self.check) {
            try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, name: "api_token"))
        }
        #expect(throws: Self.check) {
            try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, name: ""))
        }
    }

    @Test func ciphertextAndFingerprintArePaired() throws {
        let seeded = try SeededDatabase()
        var missingFingerprint = Sample.item(repositoryID: seeded.repo.id)
        missingFingerprint.valueFingerprint = nil
        #expect(throws: Self.check) { try seeded.config.insertItem(missingFingerprint) }

        var missingCiphertext = Sample.item(repositoryID: seeded.repo.id)
        missingCiphertext.valueCiphertext = nil
        #expect(throws: Self.check) { try seeded.config.insertItem(missingCiphertext) }

        // A value-missing secret has neither.
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, hasValue: false))
    }

    @Test func variableAlwaysHasAValue() throws {
        let seeded = try SeededDatabase()
        #expect(throws: Self.check) {
            try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, kind: .variable, hasValue: false))
        }
    }

    @Test func linkIDIsAUUIDOrNull() throws {
        let seeded = try SeededDatabase()
        var linked = Sample.item(repositoryID: seeded.repo.id)
        linked.linkID = ItemLinkID()
        try seeded.config.insertItem(linked)
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, name: "UNLINKED"))
        #expect(throws: Self.check) {
            try seeded.execute("UPDATE config_items SET link_id = 'group-a' WHERE id = '\(linked.id.uuidString)'")
        }
    }

    @Test func folderTablesCheckNamesValuesAndCascade() throws {
        let seeded = try SeededDatabase()
        let folder = UUID().uuidString.lowercased()
        let blob = "x'" + String(repeating: "07", count: 40) + "'"
        try seeded.execute("INSERT INTO folders (id, name, name_key, created_at, updated_at) VALUES ('\(folder)', 'Mobile App', 'mobile app', 't', 't')")
        #expect(throws: Self.unique) {
            try seeded.execute("INSERT INTO folders (id, name, name_key, created_at, updated_at) VALUES ('\(UUID().uuidString.lowercased())', 'MOBILE APP', 'mobile app', 't', 't')")
        }
        #expect(throws: Self.check) {
            try seeded.execute("INSERT INTO folders (id, name, name_key, created_at, updated_at) VALUES ('\(UUID().uuidString.lowercased())', '', '', 't', 't')")
        }
        #expect(throws: Self.check) {
            try seeded.execute("INSERT INTO folders (id, name, name_key, created_at, updated_at) VALUES ('folder-a', 'Other', 'other', 't', 't')")
        }
        func insertItem(_ name: String, kind: String = "secret", value: String? = nil, fingerprint: String? = nil, folderID: String? = nil) throws {
            let id = UUID().uuidString.lowercased()
            let valueSQL = value ?? blob
            let fingerprintSQL = fingerprint ?? blob
            try seeded.execute("""
                INSERT INTO folder_items (id, folder_id, kind, name, value_ct, value_fp, created_at, updated_at)
                VALUES ('\(id)', '\(folderID ?? folder)', '\(kind)', '\(name)', \(valueSQL), \(fingerprintSQL), 't', 't')
                """)
        }
        try insertItem("API_KEY")
        try insertItem("API_KEY", kind: "variable")
        #expect(throws: Self.unique) { try insertItem("API_KEY") }
        #expect(throws: Self.check) { try insertItem("api_key_lower") }
        #expect(throws: Self.check) { try insertItem("OTHER", kind: "token") }
        #expect(throws: StoreError.constraintViolation(.notNull)) { try insertItem("NO_VALUE", value: "NULL") }
        #expect(throws: StoreError.constraintViolation(.notNull)) { try insertItem("NO_FP", fingerprint: "NULL") }
        #expect(throws: Self.foreignKey) { try insertItem("ORPHAN", folderID: UUID().uuidString.lowercased()) }
        #expect(throws: Self.check) {
            try seeded.execute("UPDATE folder_items SET link_id = 'group-a'")
        }
        try seeded.execute("DELETE FROM folders")
        #expect(try seeded.integer("SELECT COUNT(*) FROM folder_items") == 0)
    }

    @Test func kindIsAnEnum() throws {
        let seeded = try SeededDatabase()
        #expect(throws: Self.check) {
            try seeded.execute("""
                INSERT INTO config_items (id, repository_id, kind, name, value_ct, value_fp, created_at, updated_at)
                VALUES ('a', '\(seeded.repo.id.uuidString)', 'token', 'X', x'00', x'00', 't', 't')
                """)
        }
        #expect(throws: Self.check) {
            try seeded.execute("""
                INSERT INTO config_items (id, repository_id, kind, name, verify_state, created_at, updated_at)
                VALUES ('b', '\(seeded.repo.id.uuidString)', 'secret', 'X', 'maybe', 't', 't')
                """)
        }
    }

    @Test func provenanceIsAnEnum() throws {
        let seeded = try SeededDatabase()
        #expect(throws: Self.check) {
            try seeded.execute("""
                INSERT INTO config_items (id, repository_id, kind, name, value_ct, value_fp, provenance, created_at, updated_at)
                VALUES ('c', '\(seeded.repo.id.uuidString)', 'secret', 'X', x'00', x'00', 'imported', 't', 't')
                """)
        }
        for provenance in ConfigProvenance.allCases {
            try seeded.execute("""
                INSERT INTO config_items (id, repository_id, kind, name, value_ct, value_fp, provenance, created_at, updated_at)
                VALUES ('\(provenance.rawValue)', '\(seeded.repo.id.uuidString)', 'secret',
                        'X_\(provenance.rawValue.uppercased())', x'00', x'00', '\(provenance.rawValue)', 't', 't')
                """)
        }
    }

    @Test func itemNamesAreUniquePerScopeAndKind() throws {
        let seeded = try SeededDatabase()
        let environment = Sample.environment(repositoryID: seeded.repo.id)
        try seeded.config.insertEnvironment(environment)
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id))

        // Repository level: environment_id is NULL, which COALESCE makes comparable.
        #expect(throws: Self.unique) {
            try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id))
        }
        // Same name, other kind or other scope: allowed.
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, kind: .variable))
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, scope: .environment(environment.id)))
        #expect(throws: Self.unique) {
            try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, scope: .environment(environment.id)))
        }
    }

    // MARK: - environments

    @Test(arguments: ["PRODUCCIÓN", "Produccio\u{301}n", "producción"])
    func environmentFoldKeyIsUnique(_ duplicate: String) throws {
        let seeded = try SeededDatabase()
        try seeded.config.insertEnvironment(Sample.environment(repositoryID: seeded.repo.id, name: "Producción"))
        #expect(throws: Self.unique) {
            try seeded.config.insertEnvironment(Sample.environment(repositoryID: seeded.repo.id, name: duplicate))
        }
        // Another repository may use the name.
        let other = Sample.repo(name: "fx-test-other", githubID: "R_other")
        try seeded.repos.insert(other)
        try seeded.config.insertEnvironment(Sample.environment(repositoryID: other.id, name: duplicate))
    }

    @Test func environmentNameLengthAndPolicyAreChecked() throws {
        let seeded = try SeededDatabase()
        let tooLong = String(repeating: "e", count: Limits.maxEnvironmentNameLength + 1)
        #expect(throws: Self.check) {
            try seeded.config.insertEnvironment(Sample.environment(repositoryID: seeded.repo.id, name: tooLong))
        }
        let longest = String(repeating: "e", count: Limits.maxEnvironmentNameLength)
        try seeded.config.insertEnvironment(Sample.environment(repositoryID: seeded.repo.id, name: longest))
        #expect(throws: Self.check) {
            try seeded.execute("""
                INSERT INTO environments (id, repository_id, name, name_key, branch_policy, created_at, updated_at)
                VALUES ('e', '\(seeded.repo.id.uuidString)', 'qa', 'qa', 'everything', 't', 't')
                """)
        }
    }

    // MARK: - vaults / key_wraps

    @Test func vaultIsASingleRowWithFixedBlobLengths() throws {
        let seeded = try SeededDatabase()
        try seeded.vault.createVault(Sample.vault(), keyWraps: [])
        #expect(throws: Self.primaryKey) {
            try seeded.vault.createVault(Sample.vault(), keyWraps: [])
        }
        #expect(throws: Self.check) {
            try seeded.execute("INSERT INTO vaults (id, vault_id, kcv, created_at) VALUES (2, zeroblob(16), zeroblob(16), 't')")
        }
        #expect(throws: Self.check) {
            try seeded.execute("UPDATE vaults SET vault_id = zeroblob(15)")
        }
        #expect(throws: Self.check) {
            try seeded.execute("UPDATE vaults SET kcv = zeroblob(17)")
        }
    }

    @Test func keyWrapRowsAreChecked() throws {
        let seeded = try SeededDatabase()
        var noSalt = Sample.passwordWrap()
        noSalt.salt = nil
        #expect(throws: Self.check) { try seeded.vault.saveKeyWrap(noSalt) }

        var shortSalt = Sample.passwordWrap()
        shortSalt.salt = Data(repeating: 0, count: Limits.kdfSaltBytes - 1)
        #expect(throws: Self.check) { try seeded.vault.saveKeyWrap(shortSalt) }

        var noOps = Sample.passwordWrap()
        noOps.opsLimit = nil
        #expect(throws: Self.check) { try seeded.vault.saveKeyWrap(noOps) }

        var shortWrap = Sample.recoveryWrap()
        shortWrap.wrappedDEK = Data(repeating: 0, count: Limits.wrappedDEKBytes - 1)
        #expect(throws: Self.check) { try seeded.vault.saveKeyWrap(shortWrap) }

        #expect(throws: Self.check) {
            try seeded.execute("INSERT INTO key_wraps (method, kdf_alg, wrapped_dek, dek_version, updated_at) VALUES ('touchid', 2, zeroblob(62), 1, 't')")
        }
        #expect(throws: Self.check) {
            try seeded.execute("INSERT INTO key_wraps (method, kdf_alg, wrapped_dek, dek_version, updated_at) VALUES ('recovery', 3, zeroblob(62), 1, 't')")
        }
        // HKDF needs no Argon2 parameters.
        try seeded.vault.saveKeyWrap(Sample.recoveryWrap())
        try seeded.vault.saveKeyWrap(Sample.passwordWrap())
    }

    // MARK: - accounts / repositories

    @Test func accountsAreGitHubOnlyAndCaseInsensitive() throws {
        let seeded = try SeededDatabase()
        #expect(throws: Self.check) {
            try seeded.accounts.save(AccountModel(login: "elsewhere", host: "gitlab.com", lastSeenAt: Sample.start))
        }
        #expect(throws: Self.primaryKey) {
            try seeded.execute("INSERT INTO accounts (login, last_seen_at) VALUES ('\(Sample.login.uppercased())', 't')")
        }
    }

    @Test func repositoriesAreUniqueByOwnerNameAndGitHubID() throws {
        let seeded = try SeededDatabase()
        #expect(throws: Self.unique) {
            try seeded.repos.insert(Sample.repo(owner: Sample.login.uppercased(), name: "FX-TEST-REPO", githubID: "R_new"))
        }
        #expect(throws: Self.unique) {
            try seeded.repos.insert(Sample.repo(name: "fx-test-other", githubID: seeded.repo.githubID))
        }
        // Several created-but-not-pushed repositories may have no github_id.
        try seeded.repos.insert(Sample.repo(name: "created-one", githubID: nil))
        try seeded.repos.insert(Sample.repo(name: "created-two", githubID: nil))
    }

    @Test func repositoryNeedsAKnownAccountAndValidEnums() throws {
        let seeded = try SeededDatabase()
        #expect(throws: Self.foreignKey) {
            try seeded.repos.insert(Sample.repo(account: "nobody", name: "orphan", githubID: "R_orphan"))
        }
        #expect(throws: Self.check) {
            try seeded.execute("""
                INSERT INTO repositories (id, account_login, owner_login, owner_type, name, is_private, origin, imported_at)
                VALUES ('r', '\(Sample.login)', 'o', 'Team', 'n', 1, 'imported', 't')
                """)
        }
        #expect(throws: Self.check) {
            try seeded.execute("""
                INSERT INTO repositories (id, account_login, owner_login, owner_type, name, is_private, origin, imported_at)
                VALUES ('r', '\(Sample.login)', 'o', 'User', 'n', 1, 'forked', 't')
                """)
        }
    }

    // MARK: - branch patterns / journal

    @Test func branchPatternsAreUniqueAndTyped() throws {
        let seeded = try SeededDatabase()
        let environment = Sample.environment(repositoryID: seeded.repo.id, policy: .custom([]))
        try seeded.config.insertEnvironment(environment)
        try seeded.config.insertPattern(BranchPatternModel(environmentID: environment.id, pattern: "release/*", type: .branch))
        try seeded.config.insertPattern(BranchPatternModel(environmentID: environment.id, pattern: "release/*", type: .tag))
        #expect(throws: Self.unique) {
            try seeded.config.insertPattern(BranchPatternModel(environmentID: environment.id, pattern: "release/*", type: .branch))
        }
        #expect(throws: Self.check) {
            try seeded.execute("""
                INSERT INTO deployment_branch_patterns (id, environment_id, pattern, type)
                VALUES ('p', '\(environment.id.uuidString)', 'main', 'commit')
                """)
        }
        #expect(throws: Self.foreignKey) {
            try seeded.config.insertPattern(BranchPatternModel(environmentID: EnvironmentID(), pattern: "main", type: .branch))
        }
    }

    @Test func journalStateIsAnEnum() throws {
        let seeded = try SeededDatabase()
        #expect(throws: Self.check) {
            try seeded.execute("""
                INSERT INTO sync_journal (run_id, account_login, op, command, is_write, scope_label, target_key, state, started_at)
                VALUES ('r', 'a', 'o', 'c', 1, 's', 't', 'pending', 't')
                """)
        }
    }

    @Test func journalNormalizeFlagIsABoolean() throws {
        let seeded = try SeededDatabase()
        #expect(throws: Self.check) {
            try seeded.execute("""
                INSERT INTO sync_journal (run_id, account_login, op, command, is_write, scope_label, target_key, state, started_at, did_normalize_value)
                VALUES ('r', 'a', 'o', 'c', 1, 's', 't', 'in_flight', 't', 2)
                """)
        }
    }

    // MARK: - Cascades

    @Test func deletingARepositoryCascadesAndNullsTheJournal() throws {
        let seeded = try SeededDatabase()
        let environment = Sample.environment(repositoryID: seeded.repo.id, policy: .custom([]))
        try seeded.config.insertEnvironment(environment)
        try seeded.config.insertPattern(BranchPatternModel(environmentID: environment.id, pattern: "main", type: .branch))
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id))
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, scope: .environment(environment.id)))
        let entry = try seeded.journal.appendInFlight(Sample.journal(runID: SyncRunID(), repositoryID: seeded.repo.id, startedAt: Sample.start))

        #expect(try seeded.repos.delete(id: seeded.repo.id))
        #expect(try seeded.integer("SELECT count(*) FROM environments") == 0)
        #expect(try seeded.integer("SELECT count(*) FROM config_items") == 0)
        #expect(try seeded.integer("SELECT count(*) FROM deployment_branch_patterns") == 0)
        let entryID = try #require(entry.id)
        let journalRow = try #require(try seeded.journal.fetch(id: entryID))
        #expect(journalRow.repositoryID == nil)
        #expect(try seeded.repos.delete(id: seeded.repo.id) == false)
    }

    @Test func deletingAnEnvironmentCascadesToItsChildrenOnly() throws {
        let seeded = try SeededDatabase()
        let environment = Sample.environment(repositoryID: seeded.repo.id, policy: .custom([]))
        try seeded.config.insertEnvironment(environment)
        try seeded.config.insertPattern(BranchPatternModel(environmentID: environment.id, pattern: "main", type: .branch))
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id))
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, scope: .environment(environment.id)))

        #expect(try seeded.config.deleteEnvironment(id: environment.id))
        #expect(try seeded.config.fetchItems(repositoryID: seeded.repo.id).map(\.scope) == [.repository])
        #expect(try seeded.integer("SELECT count(*) FROM deployment_branch_patterns") == 0)
    }

    @Test func accountLoginChangesCascadeAndInUseAccountsCannotBeDeleted() throws {
        let seeded = try SeededDatabase()
        // A GitHub username change. (A case-only change is no change under NOCASE, so it does
        // not cascade; the child still matches the parent without regard to case.)
        let renamed = "fx-renamed-owner"
        try seeded.execute("UPDATE accounts SET login = '\(renamed)'")
        #expect(try seeded.repos.fetch(id: seeded.repo.id)?.accountLogin == renamed)
        #expect(throws: Self.foreignKey) {
            try seeded.accounts.delete(login: renamed)
        }
    }
}
