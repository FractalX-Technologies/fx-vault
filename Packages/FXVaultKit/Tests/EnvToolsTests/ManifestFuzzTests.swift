import Foundation
import Testing
import VaultCore
@testable import EnvTools

/// Deterministic fuzzing: mutated manifests and random token soup must always parse to a
/// result (never trap or hang), with issues in line order and on real lines, and any manifest
/// produced must render and parse back to itself.
@Suite("Manifest fuzz")
struct ManifestFuzzTests {
    static let mutatedCount = 3_000
    static let soupCount = 2_000
    static let maxMutations = 6
    static let maxSoupTokens = 200
    static let largeSoupBytes = EnvToolsLimits.maxManifestBytes - 64

    /// Fragments that matter to the reader, plus names and text that matter to the schema.
    static let alphabet = [
        " ", "  ", "    ", "\n", "\r\n", "\r", "\t", "#", " # c", ":", ": ", "- ", "-", ",", "[", "]", "{", "}",
        "'", "''", "\"", "\\", "\\n", "\\q", "&a ", "*a", "!t ", "|", ">", "? ", "%", "@", "`", "---", "...",
        "a", "Z", "_", "1", "true", "false", "é", "\u{301}", "\u{202E}", "\u{200B}", "\u{FEFF}", "\u{0}", "🙂",
        "production", "staging", "provider", "vault", "project", "team", "environment", "secret", "public",
        "to", "stages", "targets", "vars", "version", "github-actions", "azure-keyvault", "supabase", "vercel",
        "SUPABASE_", "NEXT_PUBLIC_", "GITHUB_", "kv-a", "abcdefghijklmnopqrst", "prj_X1", "team_Y2",
    ]

    /// Issues a valid model may still carry (variables kept so checks can show them as blocked).
    static let policyKinds = Set<ManifestIssue.Kind>(
        [.reservedSupabasePrefix] + PublicNamePrefixes.all.map { .publicPrefixOnSecret(prefix: $0) }
    )

    @Test func mutatedManifestsAlwaysParse() throws {
        let seeds = [
            try ManifestFixture.full(),
            ManifestSerializer.render(ManifestSerializerTests.everyProviderModel),
            manifestText(vars: ["KEY: { secret: true, to: [ci], stages: [production] }"]),
            "---\nstages:\n  - production\ntargets:\n  ci:\n    provider: github-actions\nvars:\n  - A\n",
        ]
        var random = SeededGenerator(seed: 0x5EED_0001)
        var producedManifests = 0
        for iteration in 0..<Self.mutatedCount {
            var lines = (seeds[iteration % seeds.count]).components(separatedBy: "\n")
            for _ in 0..<Int.random(in: 1...Self.maxMutations, using: &random) {
                mutate(&lines, using: &random)
            }
            if check(lines.joined(separator: "\n")) { producedManifests += 1 }
        }
        // The mutations are small, so many inputs must still produce a manifest.
        #expect(producedManifests > Self.mutatedCount / 10)
    }

    @Test func randomTokenSoupAlwaysParses() {
        var random = SeededGenerator(seed: 0x5EED_0002)
        for _ in 0..<Self.soupCount {
            let count = Int.random(in: 0...Self.maxSoupTokens, using: &random)
            let text = (0..<count).map { _ in Self.alphabet.randomElement(using: &random) ?? "" }.joined()
            _ = check(text)
        }
    }

    @Test func largeRandomInputsStayWithinTheLimit() {
        var random = SeededGenerator(seed: 0x5EED_0003)
        for _ in 0..<4 {
            var text = ""
            while text.utf8.count < Self.largeSoupBytes {
                text += Self.alphabet.randomElement(using: &random) ?? ""
            }
            _ = check(String(decoding: text.utf8.prefix(Self.largeSoupBytes), as: UTF8.self))
        }
    }

    @Test func pathologicalInputs() {
        let unit = EnvToolsLimits.maxManifestBytes / 4
        let inputs = [
            String(repeating: "[", count: unit),
            String(repeating: "{a: ", count: unit / 4),
            String(repeating: "- ", count: unit / 2),
            (0..<200).map { String(repeating: " ", count: $0) + "k\($0):" }.joined(separator: "\n"),
            String(repeating: "a: b\n", count: unit / 5),
            String(repeating: "'", count: unit),
            String(repeating: "\"\\", count: unit / 2),
            String(repeating: "? \n", count: unit / 3),
            String(repeating: "|\n ", count: unit / 3),
            String(repeating: "\r", count: unit),
            String(repeating: "]}", count: unit / 2),
        ]
        for input in inputs {
            _ = check(input)
        }
    }

    // MARK: - Helpers

    /// Parses `text`, checks the invariants, and returns whether a manifest was produced.
    private func check(_ text: String) -> Bool {
        let result = ManifestParser.parse(text)
        let lineCount = max(1, ManifestTokenizer.lineRanges(of: Array(text.utf8)).count)
        #expect(result.issues.allSatisfy { (1...lineCount).contains($0.line) })
        #expect(result.issues.map(\.line) == result.issues.map(\.line).sorted())
        guard let manifest = result.manifest else { return false }
        let rendered = ManifestSerializer.render(manifest)
        let reparsed = ManifestParser.parse(rendered)
        #expect(reparsed.manifest == manifest, "\(text.debugDescription)\n\(rendered)")
        #expect(reparsed.issues.allSatisfy { Self.policyKinds.contains($0.kind) }, "\(reparsed.issues)\n\(rendered)")
        return true
    }

    private func mutate(_ lines: inout [String], using random: inout SeededGenerator) {
        guard !lines.isEmpty else {
            lines = [Self.alphabet.randomElement(using: &random) ?? ""]
            return
        }
        let lineIndex = Int.random(in: 0..<lines.count, using: &random)
        var characters = Array(lines[lineIndex])
        let position = Int.random(in: 0...characters.count, using: &random)
        let fragment = Self.alphabet.randomElement(using: &random) ?? ""
        switch Int.random(in: 0..<7, using: &random) {
        case 0:
            characters.insert(contentsOf: fragment, at: position)
            lines[lineIndex] = String(characters)
        case 1:
            let end = min(characters.count, position + Int.random(in: 1...8, using: &random))
            characters.removeSubrange(position..<end)
            lines[lineIndex] = String(characters)
        case 2:
            lines.insert(lines[lineIndex], at: lineIndex)
        case 3:
            lines.swapAt(lineIndex, Int.random(in: 0..<lines.count, using: &random))
        case 4:
            lines.remove(at: lineIndex)
        case 5:
            let spaces = String(repeating: " ", count: Int.random(in: 1...3, using: &random))
            lines[lineIndex] = Bool.random(using: &random) ? spaces + lines[lineIndex] : String(lines[lineIndex].drop { $0 == " " })
        default:
            if position < characters.count {
                characters.replaceSubrange(position...position, with: fragment)
                lines[lineIndex] = String(characters)
            } else {
                lines[lineIndex] += fragment
            }
        }
    }
}
