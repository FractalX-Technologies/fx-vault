import Foundation
import Testing
import VaultCore
@testable import EnvTools

@Suite("Manifest serializer")
struct ManifestSerializerTests {
    static let fullRendered = """
    # fxvault.yml · names and destinations, never values
    version: 1
    stages: [production, staging]

    targets:
      ci:  { provider: github-actions }
      kv:  { provider: azure-keyvault, vault: { production: kv-sample-prod, staging: kv-sample-stg } }
      api: { provider: supabase,
             project: { production: abcdefghijklmnopqrst, staging: tsrqponmlkjihgfedcba } }
      web: { provider: vercel, project: sample-web, team: example-org,
             environment: { production: production, staging: preview } }

    vars:
      DATABASE_URL:             { secret: true, to: [kv, api] }
      NEXT_PUBLIC_SUPABASE_URL: { public: true, to: [web] }
      VERCEL_TOKEN:             { secret: true, to: [ci], stages: [production] }
      AZURE_CLIENT_ID:          { to: [ci] }

    """

    @Test func rendersTheFullExample() {
        #expect(ManifestSerializer.render(ManifestFixture.fullModel) == Self.fullRendered)
    }

    @Test func renderedLinesFitTheWidth() {
        let lines = ManifestSerializer.render(ManifestFixture.fullModel).split(separator: "\n")
        #expect(lines.allSatisfy { $0.count <= ManifestSerializer.maxLineWidth })
    }

    @Test func fixtureRoundTrips() throws {
        let parsed = try #require(ManifestParser.parse(try ManifestFixture.full()).manifest)
        assertRoundTrip(parsed)
    }

    @Test func renderingIsDeterministic() {
        let model = Self.everyProviderModel
        #expect(ManifestSerializer.render(model) == ManifestSerializer.render(model))
    }

    @Test func everyProviderAndShapeRoundTrips() {
        assertRoundTrip(Self.everyProviderModel)
        let text = ManifestSerializer.render(Self.everyProviderModel)
        #expect(text.hasPrefix(ManifestSerializer.headerComment + "\n"))
        #expect(text.hasSuffix("\n"))
    }

    @Test func emptySectionsRoundTrip() {
        let model = ManifestModel(stages: ["production"], targets: [], vars: [])
        #expect(ManifestSerializer.render(model) == """
        # fxvault.yml · names and destinations, never values
        version: 1
        stages: [production]

        targets: {}

        vars: {}

        """)
        assertRoundTrip(model)
    }

    @Test func longLinesWrapAndRoundTrip() {
        let stages = (0..<EnvToolsLimits.maxManifestStages).map { "stage-\($0)" }
        let vaults = Dictionary(uniqueKeysWithValues: stages.map { ($0, "kv-\($0)") })
        let model = ManifestModel(
            stages: stages,
            targets: [ManifestTargetModel(name: "kv", configuration: .azureKeyVault(vault: .perStage(vaults)))],
            vars: [ManifestVarModel(name: "KEY", kind: .secret, targets: ["kv"], stages: Array(stages.prefix(12)))]
        )
        let text = ManifestSerializer.render(model)
        #expect(text.split(separator: "\n").count > 8)
        assertRoundTrip(model)
    }

    @Test(arguments: [
        ("production", "production"),
        ("_x.y-z9", "_x.y-z9"),
        ("Producción", "'Producción'"),
        ("my stage", "'my stage'"),
        ("it's", "'it''s'"),
        ("true", "'true'"),
        ("No", "'No'"),
        ("null", "'null'"),
        ("2024", "'2024'"),
        ("a#b", "'a#b'"),
        ("a:b", "'a:b'"),
        ("-x", "'-x'"),
        ("[x]", "'[x]'"),
        ("", "''"),
        ("a\nb\t\"c\\", #""a\nb\t\"c\\""#),
    ])
    func scalarQuoting(_ text: String, _ expected: String) {
        #expect(ManifestSerializer.scalar(text) == expected)
        // Every rendering reads back as the same text.
        let parsed = ManifestReader.read("k: \(expected)")
        guard case .mapping(let entries) = parsed.root?.value, case .scalar(let value, _) = entries.first?.value.value else {
            Issue.record("expected a scalar for \(expected)")
            return
        }
        #expect(value == text)
    }

    @Test func randomModelsRoundTrip() {
        var generator = ManifestModelGenerator(seed: 0x00F1_7A11)
        for _ in 0..<Self.randomModelCount {
            assertRoundTrip(generator.model())
        }
    }

    static let randomModelCount = 400

    // MARK: - .env.example

    @Test func envExampleForATarget() {
        let text = ManifestEnvExample.render(ManifestFixture.fullModel, target: "web", stage: nil)
        #expect(text == "# web (vercel) · every stage · from fxvault.yml, names only\nNEXT_PUBLIC_SUPABASE_URL=\n")
    }

    @Test func envExampleForATargetAndStage() {
        let model = ManifestFixture.fullModel
        #expect(ManifestEnvExample.render(model, target: "ci", stage: "production") == """
        # ci (github-actions) · production · from fxvault.yml, names only
        VERCEL_TOKEN=
        AZURE_CLIENT_ID=

        """)
        #expect(ManifestEnvExample.render(model, target: "ci", stage: "STAGING") == """
        # ci (github-actions) · staging · from fxvault.yml, names only
        AZURE_CLIENT_ID=

        """)
        #expect(ManifestEnvExample.render(model, target: "kv", stage: nil).hasSuffix("\nDATABASE_URL=\n"))
    }

    @Test func envExampleForUnknownTargetsAndStages() {
        let model = ManifestFixture.fullModel
        #expect(ManifestEnvExample.render(model, target: "nope", stage: nil) == "# nope · every stage · from fxvault.yml, names only\n")
        #expect(ManifestEnvExample.render(model, target: "ci", stage: "qa") == "# ci (github-actions) · qa · from fxvault.yml, names only\n")
        #expect(ManifestEnvExample.render(model, target: "a\nB=1", stage: "x\r\ny") == "# a B=1 · x  y · from fxvault.yml, names only\n")
    }

    @Test func envExampleReadsBackAsEmptyValues() throws {
        let text = ManifestEnvExample.render(ManifestFixture.fullModel, target: "ci", stage: nil)
        let parsed = try DotEnvParser.parse(text)
        #expect(parsed.issues.isEmpty)
        #expect(parsed.pairs == [ParsedPair("VERCEL_TOKEN", ""), ParsedPair("AZURE_CLIENT_ID", "")])
    }

    // MARK: - Helpers

    private func assertRoundTrip(_ model: ManifestModel, sourceLocation: SourceLocation = #_sourceLocation) {
        let text = ManifestSerializer.render(model)
        let result = ManifestParser.parse(text)
        #expect(result.issues.isEmpty, "\(result.issues)\n\(text)", sourceLocation: sourceLocation)
        #expect(result.manifest == model, "\(text)", sourceLocation: sourceLocation)
        if let reparsed = result.manifest {
            #expect(ManifestSerializer.render(reparsed) == text, sourceLocation: sourceLocation)
        }
    }

    /// Every provider, every setting shape, and stage names that need quoting.
    static let everyProviderModel = ManifestModel(
        stages: ["production", "staging", "Producción QA", "it's", "2024"],
        targets: [
            ManifestTargetModel(name: "ci", configuration: .githubActions(environment: nil)),
            ManifestTargetModel(name: "gh-one", configuration: .githubActions(environment: .everyStage("Shared Env"))),
            ManifestTargetModel(
                name: "gh-map",
                configuration: .githubActions(environment: .perStage(["production": "prod", "it's": "env's", "2024": "true"]))
            ),
            ManifestTargetModel(name: "kv-one", configuration: .azureKeyVault(vault: .everyStage("kv-one"))),
            ManifestTargetModel(name: "kv-map", configuration: .azureKeyVault(vault: .perStage(["staging": "Kv-Stg-01"]))),
            ManifestTargetModel(name: "kv-none", configuration: .azureKeyVault(vault: .perStage([:]))),
            ManifestTargetModel(name: "api", configuration: .supabase(project: .everyStage("abcdefghijklmnopqrst"))),
            ManifestTargetModel(
                name: "api-map",
                configuration: .supabase(project: .perStage([
                    "production": "abcdefghijklmnopqrst",
                    "Producción QA": "tsrqponmlkjihgfedcba",
                ]))
            ),
            ManifestTargetModel(name: "web", configuration: .vercel(project: "web", team: nil, environment: nil)),
            ManifestTargetModel(
                name: "web-ids",
                configuration: .vercel(project: "prj_Ab12", team: "team_Xy9", environment: .everyStage(.development))
            ),
            ManifestTargetModel(
                name: "web-map",
                configuration: .vercel(
                    project: "my.app_v2",
                    team: "example-org",
                    environment: .perStage(["production": .production, "staging": .preview, "2024": .development])
                )
            ),
        ],
        vars: [
            ManifestVarModel(name: "DATABASE_URL", kind: .secret, targets: ["kv-one", "kv-map", "api"]),
            ManifestVarModel(name: "NEXT_PUBLIC_API_URL", kind: .publicVariable, targets: ["web", "web-map"]),
            ManifestVarModel(name: "AZURE_CLIENT_ID", targets: ["ci", "gh-one", "gh-map"], stages: ["production", "it's"]),
            ManifestVarModel(name: "_PRIVATE_FLAG", kind: .secret, targets: ["web-ids", "api-map", "kv-none"], stages: ["2024"]),
        ]
    )
}

/// Builds random valid manifests from a fixed seed, for round-trip property tests.
struct ManifestModelGenerator {
    private var random: SeededGenerator

    private static let stagePool = [
        "production", "staging", "development", "preview", "Producción", "qa env", "it's", "2024", "true",
        "Preview #2", "a:b", "x-y.z", "ステージ", "-dash", "[x]",
    ]
    private static let gitHubEnvironmentPool = ["production", "Shared Env", "env's", "null", "Prod: EU", "env-1"]
    private static let vaultPool = ["kv-a", "kv-sample-01", "Vault1", "abc"]
    private static let vercelProjectPool = ["web", "prj_Ab12", "my.app_v2", "site-1"]
    private static let vercelTeamPool: [String?] = [nil, "example-org", "team_Xy9"]
    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let maxStages = 5
    private static let maxTargets = 6
    private static let maxVars = 8
    private static let projectRefLength = DestinationRules.supabaseProjectRefLength

    init(seed: UInt64) {
        random = SeededGenerator(seed: seed)
    }

    mutating func model() -> ManifestModel {
        var stages: [String] = []
        for stage in Self.stagePool.shuffled(using: &random).prefix(Int.random(in: 1...Self.maxStages, using: &random)) {
            stages.append(stage)
        }
        let targets = (0..<Int.random(in: 0...Self.maxTargets, using: &random)).map { target(index: $0, stages: stages) }
        let names = targets.map(\.name)
        let vars: [ManifestVarModel] = names.isEmpty ? [] : (0..<Int.random(in: 0...Self.maxVars, using: &random)).map { index in
            ManifestVarModel(
                name: "VAR_\(index)",
                kind: ManifestVarKind.allCases.randomElement(using: &random) ?? .variable,
                targets: subset(of: names),
                stages: Bool.random(using: &random) ? nil : subset(of: stages)
            )
        }
        return ManifestModel(stages: stages, targets: targets, vars: vars)
    }

    private mutating func target(index: Int, stages: [String]) -> ManifestTargetModel {
        let name = "t\(index)"
        let configuration: ManifestTargetConfiguration
        switch ManifestProvider.allCases.randomElement(using: &random) ?? .githubActions {
        case .githubActions:
            configuration = .githubActions(environment: Bool.random(using: &random) ? nil : stageValue(stages, pool: Self.gitHubEnvironmentPool))
        case .azureKeyVault:
            configuration = .azureKeyVault(vault: stageValue(stages, pool: Self.vaultPool))
        case .supabase:
            let refs = (0..<3).map { _ in String((0..<Self.projectRefLength).map { _ in Self.lowercase.randomElement(using: &random) ?? "a" }) }
            configuration = .supabase(project: stageValue(stages, pool: refs))
        case .vercel:
            let environment: ManifestStageValue<ManifestVercelEnvironment>? = Bool.random(using: &random)
                ? nil
                : stageValue(stages, pool: ManifestVercelEnvironment.allCases)
            configuration = .vercel(
                project: Self.vercelProjectPool.randomElement(using: &random) ?? "web",
                team: Self.vercelTeamPool.randomElement(using: &random) ?? nil,
                environment: environment
            )
        }
        return ManifestTargetModel(name: name, configuration: configuration)
    }

    private mutating func stageValue<Value: Sendable & Hashable>(_ stages: [String], pool: [Value]) -> ManifestStageValue<Value> {
        guard let fallback = pool.first else { return .perStage([:]) }
        if Bool.random(using: &random) {
            return .everyStage(pool.randomElement(using: &random) ?? fallback)
        }
        var values: [String: Value] = [:]
        for stage in stages where Bool.random(using: &random) {
            values[stage] = pool.randomElement(using: &random) ?? fallback
        }
        return .perStage(values)
    }

    /// A non-empty subset of `items`, in their order.
    private mutating func subset(of items: [String]) -> [String] {
        let chosen = items.filter { _ in Bool.random(using: &random) }
        if !chosen.isEmpty { return chosen }
        return [items.randomElement(using: &random) ?? ""]
    }
}
