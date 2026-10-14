import Foundation
import VaultCore

/// A license template from `gh repo license list`.
public struct GHLicenseTemplateModel: Sendable, Hashable, Identifiable {
    /// The key passed to `--license=` (for example `mit`).
    public let key: String
    /// The SPDX identifier (for example `MIT`).
    public let spdxID: String
    /// The display name (for example `MIT License`).
    public let name: String

    public var id: String {
        key
    }

    public init(key: String, spdxID: String, name: String) {
        self.key = key
        self.spdxID = spdxID
        self.name = name
    }
}

/// `gh repo gitignore list` and `gh repo license list` (tasks/todo.md §8 B10). Plain text,
/// parsed by line; cached for the session by the caller.
public enum GHTemplatesCommands {
    /// B10: `gh repo gitignore list`.
    public static func gitignoreList() throws(GHError) -> GHCommand {
        try GHCommand(
            operation: .gitignoreList,
            arguments: ["repo", "gitignore", "list"],
            logTemplate: "repo gitignore list"
        )
    }

    /// B10: `gh repo license list`.
    public static func licenseList() throws(GHError) -> GHCommand {
        try GHCommand(
            operation: .licenseList,
            arguments: ["repo", "license", "list"],
            logTemplate: "repo license list"
        )
    }

    /// One template name per line; invalid names are skipped.
    public static func parseGitignoreList(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { (try? GHReposCommands.validatedTemplateName($0)) != nil }
    }

    /// Non-TTY output is `key<TAB>SPDX<TAB>name` per line. Lines without tabs fall back to
    /// whitespace columns (key first). Invalid keys are skipped.
    public static func parseLicenseList(_ text: String) -> [GHLicenseTemplateModel] {
        var licenses: [GHLicenseTemplateModel] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let columns: [String]
            if line.contains("\t") {
                columns = line.split(separator: "\t", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                columns = parts.map(String.init)
            }
            guard let key = columns.first, (try? GHReposCommands.validatedTemplateName(key)) != nil else { continue }
            let spdx = columns.count > 1 ? columns[1] : key
            let name = columns.count > 2 ? columns[2] : spdx
            licenses.append(GHLicenseTemplateModel(key: key, spdxID: spdx, name: name))
        }
        return licenses
    }

    /// Decodes the gitignore list and wipes stdout.
    public static func decodeGitignoreList(_ output: GHCommandOutput) -> [String] {
        defer { output.wipe() }
        return parseGitignoreList(output.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) })
    }

    /// Decodes the license list and wipes stdout.
    public static func decodeLicenseList(_ output: GHCommandOutput) -> [GHLicenseTemplateModel] {
        defer { output.wipe() }
        return parseLicenseList(output.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) })
    }
}
