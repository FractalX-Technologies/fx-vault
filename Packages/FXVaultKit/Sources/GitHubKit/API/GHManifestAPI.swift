import Foundation
import VaultCore

/// Reads `fxvault.yml` from the root of a repository's default branch (v0.8.0, tasks/todo.md R9).
///
/// B11: `gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: …" -X GET -i
/// repos/{o}/{r}/contents/fxvault.yml`. The file holds names only; FX Vault never writes it.
public enum GHManifestAPI {
    /// The manifest's file name at the repository root.
    public static let fileName = "fxvault.yml"
    private static let getMethod = "GET"
    private static let fileType = "file"
    private static let base64Encoding = "base64"

    /// B11 for `repo`.
    public static func get(repo: GHRepoRef) throws(GHError) -> GHCommand {
        let path = try GitHubPath.rootFile(repo, name: fileName)
        return try GHCommand(
            operation: .manifestGet,
            arguments: GHEnvironmentsAPI.apiArguments(method: getMethod, path: path, includeHead: true),
            logTemplate: "api GET repos/{o}/{r}/contents/fxvault.yml"
        )
    }

    /// The file's text and blob sha, and wipes stdout.
    ///
    /// - Throws: `.malformedOutput` for a response that is not a base64 file, or a file larger
    ///   than ``Limits/maxManifestBytes`` or not valid UTF-8.
    public static func decode(_ output: GHCommandOutput) throws(GHError) -> GHManifestFileModel {
        defer { output.wipe() }
        guard let response = output.response, response.isSuccess else { throw .malformedOutput }
        let file = try GHJSONDecoding.decode(GHContentFileDTO.self, from: response.body)
        guard file.type == fileType, file.encoding == base64Encoding, file.size <= Limits.maxManifestBytes,
              let data = Data(base64Encoded: file.content, options: .ignoreUnknownCharacters),
              data.count <= Limits.maxManifestBytes,
              let text = String(data: data, encoding: .utf8)
        else { throw .malformedOutput }
        return GHManifestFileModel(text: text, sha: file.sha)
    }
}

/// `fxvault.yml` as GitHub returned it: its text and blob sha (to tell when it changed).
public struct GHManifestFileModel: Sendable, Hashable {
    public let text: String
    public let sha: String

    public init(text: String, sha: String) {
        self.text = text
        self.sha = sha
    }
}

/// The fields of a contents API file response FX Vault reads.
struct GHContentFileDTO: Decodable {
    let type: String
    let encoding: String
    let size: Int
    let sha: String
    let content: String
}
