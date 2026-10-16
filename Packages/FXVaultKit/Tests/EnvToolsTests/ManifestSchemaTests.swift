import Foundation
import Testing
import VaultCore
@testable import EnvTools

/// One schema case: manifest text, the issues it produces, and whether a manifest results.
struct SchemaCase: Sendable, CustomTestStringConvertible {
    let name: String
    let input: String
    let issues: [ManifestIssue]
    let hasManifest: Bool

    init(_ name: String, _ input: String, _ issues: [ManifestIssue], hasManifest: Bool = true) {
        self.name = name
        self.input = input
        self.issues = issues
        self.hasManifest = hasManifest
    }

    var testDescription: String { name }
}

@Suite("Manifest schema")
struct ManifestSchemaTests {
    // MARK: - The full example

    @Test func fullExampleParsesToTheExpectedModel() throws {
        let result = ManifestParser.parse(try ManifestFixture.full())
        #expect(result.issues.isEmpty)
        let manifest = try #require(result.manifest)
        #expect(manifest == ManifestFixture.fullModel)
        // Equality ignores lines, so check them on their own.
        #expect(manifest.targets.map(\.line) == ManifestFixture.fullModel.targets.map(\.line))
        #expect(manifest.vars.map(\.line) == ManifestFixture.fullModel.vars.map(\.line))
        #expect(manifest.version == 1)
    }

    @Test func fullExampleLocations() throws {
        let manifest = try #require(ManifestParser.parse(try ManifestFixture.full()).manifest)
        #expect(manifest.location(of: "ci", at: "production") == .githubEnvironment("production"))
        #expect(manifest.location(of: "ci", at: "STAGING") == .githubEnvironment("staging"))
        #expect(manifest.location(of: "kv", at: "staging") == .keyVault(vaultName: "kv-sample-stg"))
        #expect(manifest.location(of: "api", at: "production") == .supabase(projectRef: "abcdefghijklmnopqrst"))
        #expect(manifest.location(of: "web", at: "staging") == .vercel(project: "sample-web", team: "example-org", environment: .preview))
        #expect(manifest.location(of: "web", at: "qa") == nil)
        #expect(manifest.location(of: "nope", at: "production") == nil)
    }

    @Test func fullExampleQueries() throws {
        let manifest = try #require(ManifestParser.parse(try ManifestFixture.full()).manifest)
        #expect(manifest.vars(for: "production").map(\.name) == ["DATABASE_URL", "NEXT_PUBLIC_SUPABASE_URL", "VERCEL_TOKEN", "AZURE_CLIENT_ID"])
        #expect(manifest.vars(for: "Staging").map(\.name) == ["DATABASE_URL", "NEXT_PUBLIC_SUPABASE_URL", "AZURE_CLIENT_ID"])
        #expect(manifest.vars(for: "qa").isEmpty)
        #expect(manifest.vars(sentTo: "ci").map(\.name) == ["VERCEL_TOKEN", "AZURE_CLIENT_ID"])
        #expect(manifest.vars(sentTo: "ci", stage: "staging").map(\.name) == ["AZURE_CLIENT_ID"])
        #expect(manifest.vars(sentTo: "ci", stage: "qa").isEmpty)
        #expect(manifest.target(named: "kv")?.provider == .azureKeyVault)
        #expect(manifest.target(named: "KV") == nil)
        #expect(manifest.stage(matching: "PRODUCTION") == "production")
        #expect(manifest.stage(matching: "qa") == nil)
        let token = try #require(manifest.vars.first { $0.name == "VERCEL_TOKEN" })
        #expect(token.isSecret && !token.isPublic)
        #expect(token.isUsed(at: "Production") && !token.isUsed(at: "staging"))
    }

    @Test func fileNameIsTheRepositoryManifest() {
        #expect(ManifestParser.fileName == "fxvault.yml")
    }

    // MARK: - Rules (table)

    static let cases: [SchemaCase] = [
        // Document
        SchemaCase("empty file", "", [issue(1, .emptyManifest)], hasManifest: false),
        SchemaCase("only comments", "# nothing here\n\n", [issue(1, .emptyManifest)], hasManifest: false),
        SchemaCase("root is a sequence", "- a\n- b", [issue(1, .wrongType(field: nil, expected: .mapping))], hasManifest: false),
        SchemaCase("root is a scalar", "hello", [issue(1, .wrongType(field: nil, expected: .mapping))], hasManifest: false),
        SchemaCase(
            "missing sections",
            "version: 1",
            [issue(1, .missingField("stages")), issue(1, .missingField("targets")), issue(1, .missingField("vars"))],
            hasManifest: false
        ),
        SchemaCase(
            "missing vars",
            "stages: [production]\ntargets: {}",
            [issue(1, .missingField("vars"))],
            hasManifest: false
        ),
        SchemaCase(
            "targets of the wrong type with missing stages",
            "targets: [a]\nvars: {}",
            [issue(1, .missingField("stages")), issue(1, .wrongType(field: "targets", expected: .mapping))],
            hasManifest: false
        ),
        SchemaCase("vars of the wrong type", "stages: [p]\ntargets: {}\nvars: []", [issue(3, .wrongType(field: "vars", expected: .mapping))], hasManifest: false),
        SchemaCase("vars without a value", "stages: [p]\ntargets: {}\nvars:", [issue(3, .wrongType(field: "vars", expected: .mapping))], hasManifest: false),
        SchemaCase("unknown top-level field", "stages: [p]\ntargets: {}\nvars: {}\nextra: 1", [issue(4, .unknownField("extra"))]),

        // Version
        SchemaCase("version 1", "version: 1\nstages: [p]\ntargets: {}\nvars: {}", []),
        SchemaCase("version 2", "version: 2\nstages: [p]\ntargets: {}\nvars: {}", [issue(1, .unsupportedVersion)], hasManifest: false),
        SchemaCase("quoted version", "version: '1'\nstages: [p]\ntargets: {}\nvars: {}", [issue(1, .wrongType(field: "version", expected: .integer))], hasManifest: false),
        SchemaCase("version text", "version: one\nstages: [p]\ntargets: {}\nvars: {}", [issue(1, .wrongType(field: "version", expected: .integer))], hasManifest: false),

        // Stages
        SchemaCase("no stages", "stages: []\ntargets: {}\nvars: {}", [issue(1, .noStages)], hasManifest: false),
        SchemaCase("stages as a scalar", "stages: production\ntargets: {}\nvars: {}", [issue(1, .wrongType(field: "stages", expected: .sequence))], hasManifest: false),
        SchemaCase("stage that is a mapping", "stages: [p, {a: b}]\ntargets: {}\nvars: {}", [issue(1, .wrongType(field: "stages", expected: .text))]),
        SchemaCase(
            "invalid stage name",
            "stages: [production, 'a/b']\ntargets: {}\nvars: {}",
            [issue(1, .invalidStageName(.invalidPathSegment(.separator)), "a/b")]
        ),
        SchemaCase(
            "stage with leading whitespace",
            "stages: [production, ' qa']\ntargets: {}\nvars: {}",
            [issue(1, .invalidStageName(.invalidName(.leadingOrTrailingWhitespace)), " qa")]
        ),
        SchemaCase(
            "duplicate stage, case-insensitive",
            "stages:\n  - production\n  - Production\ntargets: {}\nvars: {}",
            [issue(3, .duplicateStage, "Production")]
        ),
        SchemaCase(
            "all stages invalid",
            "stages: ['..']\ntargets: {}\nvars: {}",
            [issue(1, .invalidStageName(.invalidPathSegment(.dotSegment)), "..")],
            hasManifest: false
        ),

        // Targets
        SchemaCase("invalid target name", manifestText(targets: ["Bad_Name: { provider: github-actions }"]), [issue(3, .invalidTargetName, "Bad_Name")]),
        SchemaCase("target name with a leading digit", manifestText(targets: ["1ci: { provider: github-actions }"]), [issue(3, .invalidTargetName, "1ci")]),
        SchemaCase(
            "target name too long",
            manifestText(targets: [String(repeating: "a", count: 33) + ": { provider: github-actions }"]),
            [issue(3, .invalidTargetName, String(repeating: "a", count: 33))]
        ),
        SchemaCase("target body is a scalar", manifestText(targets: ["ci: github-actions"]), [issue(3, .wrongType(field: nil, expected: .mapping), "ci")]),
        SchemaCase("missing provider", manifestText(targets: ["ci: { environment: production }"]), [issue(3, .missingField("provider"), "ci")]),
        SchemaCase("provider of the wrong type", manifestText(targets: ["ci: { provider: [github-actions] }"]), [issue(3, .wrongType(field: "provider", expected: .text), "ci")]),
        SchemaCase("unknown provider", manifestText(targets: ["ci: { provider: gitlab }"]), [issue(3, .unknownProvider, "ci")]),
        SchemaCase("unknown target field", manifestText(targets: ["ci: { provider: github-actions, color: red }"]), [issue(3, .unknownField("color"), "ci")]),
        SchemaCase(
            "field of another provider",
            manifestText(targets: ["api: { provider: supabase, project: abcdefghijklmnopqrst, vault: kv-a }"]),
            [issue(3, .unknownField("vault"), "api")]
        ),
        SchemaCase("block-style target", manifestText(targets: ["ci:", "    provider: github-actions", "    environment: prod"]), []),

        // GitHub Actions
        SchemaCase(
            "invalid GitHub environment for every stage",
            manifestText(targets: ["ci: { provider: github-actions, environment: 'a/b' }"]),
            [issue(3, .invalidGitHubEnvironment(.invalidPathSegment(.separator), stage: nil), "ci")]
        ),
        SchemaCase(
            "invalid GitHub environment for one stage",
            manifestText(targets: ["ci: { provider: github-actions, environment: { production: prod, staging: '..' } }"]),
            [issue(3, .invalidGitHubEnvironment(.invalidPathSegment(.dotSegment), stage: "staging"), "ci")]
        ),
        SchemaCase(
            "environment of the wrong type",
            manifestText(targets: ["ci: { provider: github-actions, environment: [prod] }"]),
            [issue(3, .wrongType(field: "environment", expected: .textOrMapping), "ci")]
        ),
        SchemaCase(
            "undeclared stage in a per-stage mapping",
            manifestText(targets: ["ci: { provider: github-actions, environment: { qa: qa-env } }"]),
            [issue(3, .undeclaredStage("qa"), "ci")]
        ),
        SchemaCase(
            "stage twice in a per-stage mapping",
            manifestText(targets: ["ci: { provider: github-actions, environment: { production: a, PRODUCTION: b } }"]),
            [issue(3, .duplicateReference("PRODUCTION"), "ci")]
        ),
        SchemaCase(
            "per-stage value of the wrong type",
            manifestText(targets: ["ci: { provider: github-actions, environment: { production: [a] } }"]),
            [issue(3, .wrongType(field: "environment", expected: .text), "ci")]
        ),

        // Azure Key Vault
        SchemaCase("missing vault", manifestText(targets: ["kv: { provider: azure-keyvault }"]), [issue(3, .missingField("vault"), "kv")]),
        SchemaCase("invalid vault for every stage", manifestText(targets: ["kv: { provider: azure-keyvault, vault: kv--x }"]), [issue(3, .invalidVaultName(stage: nil), "kv")]),
        SchemaCase(
            "invalid vault for one stage",
            manifestText(targets: ["kv: { provider: azure-keyvault,", "       vault: { production: kv-a, staging: 9kv } }"]),
            [issue(4, .invalidVaultName(stage: "staging"), "kv")]
        ),

        // Supabase
        SchemaCase("missing project ref", manifestText(targets: ["api: { provider: supabase }"]), [issue(3, .missingField("project"), "api")]),
        SchemaCase("short project ref", manifestText(targets: ["api: { provider: supabase, project: abc }"]), [issue(3, .invalidProjectRef(stage: nil), "api")]),
        SchemaCase(
            "uppercase project ref for one stage",
            manifestText(targets: ["api: { provider: supabase, project: { production: ABCDEFGHIJKLMNOPQRST } }"]),
            [issue(3, .invalidProjectRef(stage: "production"), "api")]
        ),

        // Vercel
        SchemaCase("missing Vercel project", manifestText(targets: ["web: { provider: vercel }"]), [issue(3, .missingField("project"), "web")]),
        SchemaCase("invalid Vercel project", manifestText(targets: ["web: { provider: vercel, project: Web-App }"]), [issue(3, .invalidVercelProject, "web")]),
        SchemaCase("invalid Vercel team", manifestText(targets: ["web: { provider: vercel, project: web, team: my_team }"]), [issue(3, .invalidVercelTeam, "web")]),
        SchemaCase(
            "invalid Vercel environment for every stage",
            manifestText(targets: ["web: { provider: vercel, project: web, environment: staging }"]),
            [issue(3, .invalidVercelEnvironment(stage: nil), "web")]
        ),
        SchemaCase(
            "invalid Vercel environment for one stage",
            manifestText(targets: ["web: { provider: vercel, project: web, environment: { production: prod } }"]),
            [issue(3, .invalidVercelEnvironment(stage: "production"), "web")]
        ),
        SchemaCase("Vercel ids", manifestText(targets: ["web: { provider: vercel, project: prj_AbC123, team: team_XyZ789 }"]), []),

        // Variables
        SchemaCase("lowercase variable name", manifestText(vars: ["database_url: { to: [ci] }"]), [issue(5, .varNameNotUppercase, "database_url")]),
        SchemaCase("GITHUB_ prefix", manifestText(vars: ["GITHUB_TOKEN: { to: [ci] }"]), [issue(5, .invalidVarName(.reservedPrefix), "GITHUB_TOKEN")]),
        SchemaCase("leading digit", manifestText(vars: ["1KEY: { to: [ci] }"]), [issue(5, .invalidVarName(.leadingDigit), "1KEY")]),
        SchemaCase("dash in a variable name", manifestText(vars: ["MY-KEY: { to: [ci] }"]), [issue(5, .invalidVarName(.invalidCharacter), "MY-KEY")]),
        SchemaCase("variable body is a list", manifestText(vars: ["KEY: [ci]"]), [issue(5, .wrongType(field: nil, expected: .mapping), "KEY")]),
        SchemaCase("secret and public", manifestText(vars: ["KEY: { secret: true, public: true, to: [ci] }"]), [issue(5, .secretAndPublic, "KEY")]),
        SchemaCase("secret as text", manifestText(vars: ["KEY: { secret: yes, to: [ci] }"]), [issue(5, .wrongType(field: "secret", expected: .boolean), "KEY")]),
        SchemaCase("quoted boolean", manifestText(vars: ["KEY: { public: 'true', to: [ci] }"]), [issue(5, .wrongType(field: "public", expected: .boolean), "KEY")]),
        SchemaCase("explicit false", manifestText(vars: ["KEY: { secret: false, public: false, to: [ci] }"]), []),
        SchemaCase("missing to", manifestText(vars: ["KEY: { secret: true }"]), [issue(5, .missingField("to"), "KEY")]),
        SchemaCase("to as a scalar", manifestText(vars: ["KEY: { to: ci }"]), [issue(5, .wrongType(field: "to", expected: .sequence), "KEY")]),
        SchemaCase("empty to", manifestText(vars: ["KEY: { to: [] }"]), [issue(5, .noTargets, "KEY")]),
        SchemaCase("undefined target", manifestText(vars: ["KEY: { to: [nope] }"]), [issue(5, .undefinedTarget("nope"), "KEY")]),
        SchemaCase("one undefined target of two", manifestText(vars: ["KEY: { to: [ci, nope] }"]), [issue(5, .undefinedTarget("nope"), "KEY")]),
        SchemaCase("target twice", manifestText(vars: ["KEY: { to: [ci, ci] }"]), [issue(5, .duplicateReference("ci"), "KEY")]),
        SchemaCase("undeclared variable stage", manifestText(vars: ["KEY: { to: [ci], stages: [qa] }"]), [issue(5, .undeclaredStage("qa"), "KEY")]),
        SchemaCase("empty variable stages", manifestText(vars: ["KEY: { to: [ci], stages: [] }"]), [issue(5, .noStages, "KEY")]),
        SchemaCase("variable stage twice", manifestText(vars: ["KEY: { to: [ci], stages: [production, Production] }"]), [issue(5, .duplicateReference("Production"), "KEY")]),
        SchemaCase("variable stages as a scalar", manifestText(vars: ["KEY: { to: [ci], stages: production }"]), [issue(5, .wrongType(field: "stages", expected: .sequence), "KEY")]),
        SchemaCase("unknown variable field", manifestText(vars: ["KEY: { to: [ci], value: x }"]), [issue(5, .unknownField("value"), "KEY")]),
        SchemaCase(
            "variable in block style",
            manifestText(vars: ["KEY:", "    secret: true", "    to:", "      - ci"]),
            []
        ),
        SchemaCase(
            "variables after a broken one",
            manifestText(vars: ["BAD: { to: [] }", "GOOD: { to: [ci] }"]),
            [issue(5, .noTargets, "BAD")]
        ),
    ]

    @Test("rules", arguments: cases)
    func rules(_ testCase: SchemaCase) {
        let result = ManifestParser.parse(testCase.input)
        #expect(result.issues == testCase.issues)
        #expect((result.manifest != nil) == testCase.hasManifest)
    }

    @Test func tableIsLarge() {
        #expect(Self.cases.count >= 70)
    }

    // MARK: - What errors leave out

    @Test func invalidStageIsLeftOutAndOthersKept() throws {
        let result = ManifestParser.parse("stages: [production, 'a/b', staging, 2024]\ntargets: {}\nvars: {}")
        #expect(try #require(result.manifest).stages == ["production", "staging", "2024"])
    }

    @Test func stagesAreStoredInNFC() throws {
        let decomposed = "Produccio\u{301}n"
        let result = ManifestParser.parse("stages: ['\(decomposed)']\ntargets: {}\nvars: {}")
        let stages = try #require(result.manifest).stages
        #expect(stages.map { Array($0.unicodeScalars) } == [Array("Producci\u{F3}n".unicodeScalars)])
        #expect(result.issues.isEmpty)
    }

    @Test func perStageEntriesMatchStagesCaseInsensitively() throws {
        let text = manifestText(targets: ["kv: { provider: azure-keyvault, vault: { PRODUCTION: kv-a } }"])
        let result = ManifestParser.parse(text)
        #expect(result.issues.isEmpty)
        let target = try #require(result.manifest?.target(named: "kv"))
        #expect(target.configuration == .azureKeyVault(vault: .perStage(["production": "kv-a"])))
        #expect(target.location(for: "production") == .keyVault(vaultName: "kv-a"))
        #expect(target.location(for: "staging") == nil)
    }

    @Test func invalidPerStageEntryLeavesTheStageUnused() throws {
        let text = manifestText(targets: ["kv: { provider: azure-keyvault, vault: { production: kv-a, staging: kv--b } }"], vars: ["KEY: { secret: true, to: [kv] }"])
        let manifest = try #require(ManifestParser.parse(text).manifest)
        #expect(manifest.location(of: "kv", at: "production") == .keyVault(vaultName: "kv-a"))
        #expect(manifest.location(of: "kv", at: "staging") == nil)
        #expect(manifest.vars.map(\.name) == ["KEY"])
    }

    @Test func droppedTargetDoesNotCascade() throws {
        let text = manifestText(
            targets: ["ci: { provider: github-actions }", "kv: { provider: azure-keyvault, vault: kv--bad }"],
            vars: ["ONLY_KV: { secret: true, to: [kv] }", "BOTH: { to: [kv, ci] }"]
        )
        let result = ManifestParser.parse(text)
        #expect(result.issues == [issue(4, .invalidVaultName(stage: nil), "kv")])
        let manifest = try #require(result.manifest)
        #expect(manifest.targets.map(\.name) == ["ci"])
        #expect(manifest.vars == [ManifestVarModel(name: "BOTH", targets: ["ci"])])
    }

    @Test func undefinedReferenceIsDroppedAndTheVariableKept() throws {
        let manifest = try #require(ManifestParser.parse(manifestText(vars: ["KEY: { to: [nope, ci] }"])).manifest)
        #expect(manifest.vars == [ManifestVarModel(name: "KEY", targets: ["ci"])])
    }

    @Test func repeatedReferencesAreKeptOnce() throws {
        let manifest = try #require(ManifestParser.parse(manifestText(vars: ["KEY: { to: [ci, ci], stages: [staging, STAGING] }"])).manifest)
        #expect(manifest.vars == [ManifestVarModel(name: "KEY", targets: ["ci"], stages: ["staging"])])
    }

    @Test func unknownFieldsAreWarningsAndTheModelIsKept() throws {
        let text = manifestText(targets: ["ci: { provider: github-actions, note: x }"], vars: ["KEY: { to: [ci], comment: y }"]) + "notes: z\n"
        let result = ManifestParser.parse(text)
        #expect(!result.hasErrors)
        #expect(result.issues.map(\.severity) == [.warning, .warning, .warning])
        #expect(try #require(result.manifest).vars.map(\.name) == ["KEY"])
    }

    @Test func gitHubEnvironmentDefaultsToTheStageName() throws {
        let text = manifestText(targets: [
            "ci: { provider: github-actions }",
            "one: { provider: github-actions, environment: shared }",
            "map: { provider: github-actions, environment: { staging: Staging-Env } }",
        ])
        let manifest = try #require(ManifestParser.parse(text).manifest)
        #expect(manifest.location(of: "ci", at: "staging") == .githubEnvironment("staging"))
        #expect(manifest.location(of: "one", at: "production") == .githubEnvironment("shared"))
        #expect(manifest.location(of: "map", at: "staging") == .githubEnvironment("Staging-Env"))
        #expect(manifest.location(of: "map", at: "production") == nil)
    }

    @Test func vercelDefaultsAndSingleEnvironment() throws {
        let text = manifestText(
            stages: "[Production, development, staging]",
            targets: [
                "web: { provider: vercel, project: web }",
                "all: { provider: vercel, project: web, team: example-org, environment: preview }",
            ]
        )
        let manifest = try #require(ManifestParser.parse(text).manifest)
        #expect(manifest.location(of: "web", at: "production") == .vercel(project: "web", team: nil, environment: .production))
        #expect(manifest.location(of: "web", at: "development") == .vercel(project: "web", team: nil, environment: .development))
        #expect(manifest.location(of: "web", at: "staging") == .vercel(project: "web", team: nil, environment: .preview))
        #expect(manifest.location(of: "all", at: "Production") == .vercel(project: "web", team: "example-org", environment: .preview))
    }

    @Test(arguments: [
        ("production", ManifestVercelEnvironment.production),
        ("PRODUCTION", .production),
        ("Development", .development),
        ("staging", .preview),
        ("preview", .preview),
        ("prod", .preview),
    ])
    func vercelDefaultEnvironment(_ stage: String, _ expected: ManifestVercelEnvironment) {
        #expect(ManifestVercelEnvironment.defaultEnvironment(forStage: stage) == expected)
    }

    // MARK: - Destination name rules

    @Test(arguments: PublicNamePrefixes.all)
    func publicPrefixOnASecretSentToVercel(_ prefix: String) throws {
        let name = prefix + "KEY"
        let text = manifestText(
            targets: ["ci: { provider: github-actions }", "web: { provider: vercel, project: web }"],
            vars: ["\(name): { secret: true, to: [ci, web] }"]
        )
        let result = ManifestParser.parse(text)
        #expect(result.issues == [issue(varLine(0, targetCount: 2), .publicPrefixOnSecret(prefix: prefix), name)])
        // Kept, so destination checks can show it as blocked.
        #expect(try #require(result.manifest).vars.map(\.name) == [name])
    }

    @Test func publicPrefixIsFineWhenNotSecretOrNotVercel() {
        let text = manifestText(
            targets: ["ci: { provider: github-actions }", "web: { provider: vercel, project: web }"],
            vars: ["NEXT_PUBLIC_A: { public: true, to: [web] }", "NEXT_PUBLIC_B: { to: [web] }", "NEXT_PUBLIC_C: { secret: true, to: [ci] }"]
        )
        #expect(ManifestParser.parse(text).issues.isEmpty)
    }

    @Test func supabaseReservedPrefix() throws {
        let text = manifestText(
            targets: ["ci: { provider: github-actions }", "api: { provider: supabase, project: abcdefghijklmnopqrst }"],
            vars: ["SUPABASE_URL: { to: [api] }", "SUPABASE_KEY: { secret: true, to: [ci] }"]
        )
        let result = ManifestParser.parse(text)
        #expect(result.issues == [issue(varLine(0, targetCount: 2), .reservedSupabasePrefix, "SUPABASE_URL")])
        #expect(try #require(result.manifest).vars.map(\.name) == ["SUPABASE_URL", "SUPABASE_KEY"])
    }

    // MARK: - Identifier formats (Key Vault and Supabase through DestinationRules)

    @Test(arguments: [
        ("kv-a1", true), ("abc", true), ("Kv-Sample-01", true), (String(repeating: "a", count: 24), true),
        ("ab", false), (String(repeating: "a", count: 25), false), ("1kv", false), ("kv-", false),
        ("kv--a", false), ("kv_a", false), ("kv.a", false), ("kvé", false), ("", false),
    ])
    func keyVaultNames(_ name: String, _ isValid: Bool) {
        let vault = ManifestSerializer.scalar(name)
        let result = ManifestParser.parse(manifestText(targets: ["kv: { provider: azure-keyvault, vault: \(vault) }"]))
        #expect(result.issues == (isValid ? [] : [issue(3, .invalidVaultName(stage: nil), "kv")]))
    }

    @Test(arguments: [
        ("abcdefghijklmnopqrst", true), ("abcdefghijklmnopqrs", false), ("abcdefghijklmnopqrstu", false),
        ("Abcdefghijklmnopqrst", false), ("abcdefghijklmnopqrs1", false), ("", false),
    ])
    func supabaseProjectRefs(_ ref: String, _ isValid: Bool) {
        let project = ManifestSerializer.scalar(ref)
        let result = ManifestParser.parse(manifestText(targets: ["api: { provider: supabase, project: { staging: \(project) } }"]))
        #expect(result.issues == (isValid ? [] : [issue(3, .invalidProjectRef(stage: "staging"), "api")]))
    }

    @Test(arguments: [
        ("web", true), ("my.app_v2-x", true), ("prj_AbC123", true), (String(repeating: "a", count: 100), true),
        ("", false), ("Web", false), ("my app", false), (String(repeating: "a", count: 101), false), ("prj_", true),
        ("prj_A-b", false),
    ])
    func vercelProjects(_ project: String, _ isValid: Bool) {
        // `prj_` alone is a valid slug ([a-z0-9._-]); `prj_A-b` is neither a slug nor an id.
        #expect(ManifestIdentifierValidator.isValidVercelProject(project) == isValid)
    }

    @Test(arguments: [
        ("example-org", true), ("team_XyZ789", true), (String(repeating: "a", count: 48), true),
        ("", false), ("Example", false), ("my_team", false), (String(repeating: "a", count: 49), false), ("team_", false),
    ])
    func vercelTeams(_ team: String, _ isValid: Bool) {
        #expect(ManifestIdentifierValidator.isValidVercelTeam(team) == isValid)
    }

    @Test(arguments: [
        ("ci", true), ("web-2", true), ("a", true), (String(repeating: "a", count: 32), true),
        ("", false), ("Ci", false), ("2ci", false), ("-ci", false), ("c_i", false), (String(repeating: "a", count: 33), false),
    ])
    func targetNames(_ name: String, _ isValid: Bool) {
        #expect(ManifestIdentifierValidator.isValidTargetName(name) == isValid)
    }

    // MARK: - Limits

    @Test func fileAtTheSizeLimitIsRead() {
        let body = manifestText()
        let padding = EnvToolsLimits.maxManifestBytes - body.utf8.count
        let text = body + "#" + String(repeating: "x", count: padding - 1)
        #expect(text.utf8.count == EnvToolsLimits.maxManifestBytes)
        let result = ManifestParser.parse(text)
        #expect(result.manifest != nil)
        #expect(result.issues.isEmpty)
    }

    @Test func fileOverTheSizeLimitIsRejected() {
        let text = manifestText() + "#" + String(repeating: "x", count: EnvToolsLimits.maxManifestBytes)
        let result = ManifestParser.parse(text)
        #expect(result.manifest == nil)
        #expect(result.issues == [issue(1, .fileTooLarge(limit: EnvToolsLimits.maxManifestBytes))])
    }

    @Test func stageLimit() {
        let stages = (0..<EnvToolsLimits.maxManifestStages).map { "s\($0)" }
        let atLimit = ManifestParser.parse(manifestText(stages: "[" + stages.joined(separator: ", ") + "]"))
        #expect(atLimit.manifest?.stages.count == EnvToolsLimits.maxManifestStages)
        let over = ManifestParser.parse(manifestText(stages: "[" + (stages + ["extra"]).joined(separator: ", ") + "]"))
        #expect(over.manifest == nil)
        #expect(over.issues == [issue(1, .tooManyStages(limit: EnvToolsLimits.maxManifestStages))])
    }

    @Test func targetLimit() {
        let targets = (0..<EnvToolsLimits.maxManifestTargets).map { "t\($0): { provider: github-actions }" }
        #expect(ManifestParser.parse(manifestText(targets: targets)).manifest?.targets.count == EnvToolsLimits.maxManifestTargets)
        let over = ManifestParser.parse(manifestText(targets: targets + ["extra: { provider: github-actions }"]))
        #expect(over.manifest == nil)
        #expect(over.issues == [issue(3, .tooManyTargets(limit: EnvToolsLimits.maxManifestTargets))])
    }

    @Test func variableLimit() {
        let vars = (0..<EnvToolsLimits.maxManifestVars).map { "V\($0): { to: [ci] }" }
        let atLimit = ManifestParser.parse(manifestText(vars: vars))
        #expect(atLimit.issues.isEmpty)
        #expect(atLimit.manifest?.vars.count == EnvToolsLimits.maxManifestVars)
        let over = ManifestParser.parse(manifestText(vars: vars + ["EXTRA: { to: [ci] }"]))
        #expect(over.manifest == nil)
        #expect(over.issues == [issue(varLine(0), .tooManyVars(limit: EnvToolsLimits.maxManifestVars))])
    }

    @Test func nestingLimitThroughTheParser() {
        let text = manifestText(targets: ["ci: { provider: github-actions, environment: { production: [[[[[x]]]]] } }"])
        let result = ManifestParser.parse(text)
        // Only the innermost level is cut; the outer sequences are still not a name.
        #expect(result.issues == [
            issue(3, .nestingTooDeep(limit: EnvToolsLimits.maxManifestNestingDepth)),
            issue(3, .wrongType(field: "environment", expected: .text), "ci"),
        ])
        #expect(result.manifest?.location(of: "ci", at: "production") == nil)
    }

    // MARK: - Recovery

    @Test func forgottenClosingBraceIsOneIssue() throws {
        var lines = try ManifestFixture.full().components(separatedBy: "\n")
        lines[5] = "  ci:  { provider: github-actions    # the closing brace is missing"
        let result = ManifestParser.parse(lines.joined(separator: "\n"))
        // `vars` was swallowed by the open brace, not left out: only the brace is reported.
        #expect(result.issues == [issue(6, .unterminatedFlowCollection)])
        #expect(result.manifest == nil)
    }

    @Test func tabIndentedLinesAreEachReported() throws {
        let text = try ManifestFixture.full().replacingOccurrences(of: "\n  DATABASE_URL", with: "\n\tDATABASE_URL")
        let result = ManifestParser.parse(text)
        #expect(result.issues == [issue(15, .tabInIndentation)])
        #expect(try #require(result.manifest).vars.map(\.name) == ["NEXT_PUBLIC_SUPABASE_URL", "VERCEL_TOKEN", "AZURE_CLIENT_ID"])
    }

    // MARK: - Issues

    @Test func namesInIssuesAreSanitized() {
        let text = manifestText(stages: "[production, \"q\u{200B}a/\u{202E}x\"]", vars: ["KEY: { to: [\"n\u{202E}o\"] }"])
        let result = ManifestParser.parse(text)
        #expect(result.issues.map(\.key) == ["qa/x", "KEY"])
        #expect(result.issues.last?.kind == .undefinedTarget("no"))
    }

    @Test func issuesAreOrderedByLine() {
        let text = "stages: [production]\nextra: 1\ntargets:\n  ci: { provider: github-actions, x: 1 }\n  bad: { provider: nope }\nvars:\n  K: { to: [ci], y: 2 }\n  &a\n"
        let result = ManifestParser.parse(text)
        #expect(result.issues.map(\.line) == result.issues.map(\.line).sorted())
        #expect(result.issues(onLine: 4) == [issue(4, .unknownField("x"), "ci")])
    }

    @Test func severities() {
        #expect(issue(1, .unknownField("x")).severity == .warning)
        #expect(issue(1, .duplicateReference("x")).severity == .warning)
        #expect(issue(1, .undefinedTarget("x")).severity == .error)
        #expect(issue(1, .publicPrefixOnSecret(prefix: "VITE_")).severity == .error)
        #expect(issue(1, .reservedSupabasePrefix).severity == .error)
        #expect(issue(1, .unsupported(.anchor)).severity == .error)
        #expect(issue(1, .fileTooLarge(limit: 1)).severity == .error)
    }

    @Test func issuesNeverCarryValues() {
        // The value of a mistakenly inlined variable never appears in an issue.
        let value = "postgres://user-a:not-a-password@db.example.test/app"
        let text = manifestText(vars: ["DATABASE_URL: \(value)"])
        let result = ManifestParser.parse(text)
        #expect(result.issues == [issue(5, .wrongType(field: nil, expected: .mapping), "DATABASE_URL")])
        #expect(!String(describing: result.issues).contains("not-a-password"))
    }
}
