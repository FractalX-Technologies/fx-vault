import Foundation
import VaultCore

/// A gh release version (tasks/todo.md §8 A1, D5).
public struct GHVersion: Sendable, Hashable, Comparable, CustomStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `MAJOR.MINOR.PATCH` (a leading `v` is accepted; pre-release suffixes after the
    /// patch number are ignored).
    public init?(string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" {
            text = text.dropFirst()
        }
        let parts = text.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == Self.componentCount,
              let major = Self.number(parts[0]),
              let minor = Self.number(parts[1]),
              let patch = Self.number(Self.leadingDigits(parts[2]))
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    /// Parses the first line of `gh --version`: `^gh version (\d+)\.(\d+)\.(\d+)`.
    public init?(ghVersionOutput output: String) {
        guard let firstLine = output.split(separator: "\n", omittingEmptySubsequences: false).first,
              firstLine.hasPrefix(Self.outputPrefix)
        else { return nil }
        let rest = firstLine.dropFirst(Self.outputPrefix.count)
        guard let token = rest.split(separator: " ", omittingEmptySubsequences: true).first,
              token.first?.isNumber == true
        else { return nil }
        self.init(string: String(token))
    }

    /// The supported floor, `Limits.minimumGHVersion` (2.97.0, D5).
    public static let minimum: GHVersion = {
        guard let version = GHVersion(string: Limits.minimumGHVersion) else {
            preconditionFailure("Limits.minimumGHVersion is not MAJOR.MINOR.PATCH")
        }
        return version
    }()

    /// True when this version is at least ``minimum``.
    public var isSupported: Bool {
        self >= Self.minimum
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: GHVersion, rhs: GHVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    private static let componentCount = 3
    private static let outputPrefix = "gh version "

    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    private static func leadingDigits(_ text: Substring) -> Substring {
        text.prefix(while: { $0.isASCII && $0.isNumber })
    }
}
