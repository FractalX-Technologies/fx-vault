import Foundation
import Testing
import VaultCore
@testable import EnvTools

/// The reader's node tree without lines, for table assertions.
indirect enum YAMLValue: Hashable, Sendable, CustomStringConvertible {
    case plain(String)
    case single(String)
    case double(String)
    case map([YAMLPair])
    case seq([YAMLValue])
    case null
    case invalid

    var description: String {
        switch self {
        case .plain(let text): text
        case .single(let text): "'\(text)'"
        case .double(let text): text.debugDescription
        case .map(let pairs): "{" + pairs.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
        case .seq(let items): "[" + items.map(\.description).joined(separator: ", ") + "]"
        case .null: "~"
        case .invalid: "<invalid>"
        }
    }
}

struct YAMLPair: Hashable, Sendable {
    let key: String
    let value: YAMLValue
}

/// `m(("a", .plain("b")))` builds a mapping.
func m(_ pairs: (String, YAMLValue)...) -> YAMLValue {
    .map(pairs.map { YAMLPair(key: $0.0, value: $0.1) })
}

extension ManifestNode {
    var yaml: YAMLValue {
        switch value {
        case .scalar(let text, .plain): .plain(text)
        case .scalar(let text, .singleQuoted): .single(text)
        case .scalar(let text, .doubleQuoted): .double(text)
        case .mapping(let entries): .map(entries.map { YAMLPair(key: $0.key, value: $0.value.yaml) })
        case .sequence(let items): .seq(items.map(\.yaml))
        case .null: .null
        case .invalid: .invalid
        }
    }
}

/// An issue with no key (reader issues and document-level schema issues).
func issue(_ line: Int, _ kind: ManifestIssue.Kind, _ key: String? = nil) -> ManifestIssue {
    ManifestIssue(line: line, kind: kind, key: key)
}

enum ManifestFixture {
    /// The text of a file in `Fixtures/`.
    static func text(_ name: String) throws -> String {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try String(contentsOf: fixtures.appending(path: name), encoding: .utf8)
    }

    /// `Fixtures/manifest-full.yml`.
    static func full() throws -> String {
        try text("manifest-full.yml")
    }

    /// The model `manifest-full.yml` describes.
    static let fullModel = ManifestModel(
        stages: ["production", "staging"],
        targets: [
            ManifestTargetModel(name: "ci", configuration: .githubActions(environment: nil), line: 6),
            ManifestTargetModel(
                name: "kv",
                configuration: .azureKeyVault(vault: .perStage(["production": "kv-sample-prod", "staging": "kv-sample-stg"])),
                line: 7
            ),
            ManifestTargetModel(
                name: "api",
                configuration: .supabase(project: .perStage([
                    "production": "abcdefghijklmnopqrst",
                    "staging": "tsrqponmlkjihgfedcba",
                ])),
                line: 9
            ),
            ManifestTargetModel(
                name: "web",
                configuration: .vercel(
                    project: "sample-web",
                    team: "example-org",
                    environment: .perStage(["production": .production, "staging": .preview])
                ),
                line: 11
            ),
        ],
        vars: [
            ManifestVarModel(name: "DATABASE_URL", kind: .secret, targets: ["kv", "api"], line: 15),
            ManifestVarModel(name: "NEXT_PUBLIC_SUPABASE_URL", kind: .publicVariable, targets: ["web"], line: 16),
            ManifestVarModel(name: "VERCEL_TOKEN", kind: .secret, targets: ["ci"], stages: ["production"], line: 17),
            ManifestVarModel(name: "AZURE_CLIENT_ID", targets: ["ci"], line: 18),
        ]
    )
}

/// Wraps target and variable lines into a manifest: line 1 `stages`, line 2 `targets:`, the
/// target lines from line 3, then `vars:` and the variable lines.
func manifestText(
    stages: String = "[production, staging]",
    targets: [String] = ["ci: { provider: github-actions }"],
    vars: [String] = []
) -> String {
    var lines = ["stages: \(stages)"]
    lines.append(targets.isEmpty ? "targets: {}" : "targets:")
    lines += targets.map { "  " + $0 }
    lines.append(vars.isEmpty ? "vars: {}" : "vars:")
    lines += vars.map { "  " + $0 }
    return lines.joined(separator: "\n") + "\n"
}

/// The line `manifestText` puts the variable at `index` on.
func varLine(_ index: Int, targetCount: Int = 1) -> Int {
    // stages, targets:, the targets, vars:, then the variables.
    3 + targetCount + 1 + index
}
