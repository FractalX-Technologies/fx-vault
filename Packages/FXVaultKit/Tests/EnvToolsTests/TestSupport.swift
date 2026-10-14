import Foundation
import Testing
import VaultCore
@testable import EnvTools

/// A parsed entry with its value decoded, for assertions.
struct ParsedPair: Hashable, Sendable, CustomStringConvertible {
    let key: String
    let value: String
    let line: Int?

    init(_ key: String, _ value: String, line: Int? = nil) {
        self.key = key
        self.value = value
        self.line = line
    }

    var description: String {
        "\(key)=\(value.debugDescription)@\(line.map(String.init) ?? "-")"
    }
}

extension DotEnvParseResult {
    /// Entries as (key, value) pairs, ignoring lines.
    var pairs: [ParsedPair] {
        entries.map { ParsedPair($0.key, $0.value.utf8String() ?? "<invalid>") }
    }

    /// Entries as (key, value, line) triples.
    var pairsWithLines: [ParsedPair] {
        entries.map { ParsedPair($0.key, $0.value.utf8String() ?? "<invalid>", line: $0.line) }
    }
}

/// SplitMix64: a small deterministic generator, so property tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

enum TestValues {
    static let alphanumerics = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    static let upperAlphanumerics = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// A deterministic random-looking token. Built at run time so secret scanners (gitleaks)
    /// never see a token-shaped literal in the source.
    static func randomToken(length: Int, alphabet: [Character] = alphanumerics, seed: UInt64) -> String {
        var generator = SeededGenerator(seed: seed)
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator) ?? "x" })
    }

    /// A unique, empty temporary folder (removed by the caller with `removeItem`).
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "EnvToolsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A thread-safe box for values captured by `@Sendable` test hooks.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
