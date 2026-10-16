/// Reads `fxvault.yml`, the manifest a repository commits at its root to list, by name only,
/// the variables a project needs, for which stages, and where each one goes.
///
/// ```yaml
/// version: 1
/// stages: [production, staging]
/// targets:
///   ci: { provider: github-actions }
///   kv: { provider: azure-keyvault, vault: { production: kv-a, staging: kv-b } }
/// vars:
///   DATABASE_URL: { secret: true, to: [kv] }
///   AZURE_CLIENT_ID: { to: [ci] }
/// ```
///
/// The format is a strict YAML subset:
/// - Block mappings by indentation (spaces only; a tab in indentation is an issue), block
///   sequences (`- item`, also at the column of the key that owns them), flow mappings `{ }`
///   and flow sequences `[ ]` that may nest and span lines.
/// - Plain scalars, single-quoted scalars (`''` is a quote) and double-quoted scalars (escapes
///   `\"`, `\\`, `\n`, `\t` only). Quoted scalars end on their line. Unquoted `true`/`false` are
///   booleans and unquoted decimal integers are integers; any scalar can be text.
/// - Comments (`#` at the start of a line or after whitespace, outside quotes), blank lines,
///   `\n`, `\r\n` or `\r` line breaks, a leading BOM, and an optional leading `---` line.
/// - Not supported, each reported with its line: anchors and aliases, tags, block scalars,
///   directives, multiple documents, complex keys, duplicate keys and non-scalar keys.
///
/// Parsing never throws or traps: every problem becomes a ``ManifestIssue``, and the manifest is
/// nil only when the document cannot produce a coherent one (see ``ManifestParseResult``).
public enum ManifestParser {
    /// The manifest's file name at the repository root.
    public static let fileName = "fxvault.yml"

    /// Parses manifest text.
    public static func parse(_ text: String) -> ManifestParseResult {
        guard text.utf8.count <= EnvToolsLimits.maxManifestBytes else {
            let issue = ManifestIssue(
                line: 1,
                kind: .fileTooLarge(limit: EnvToolsLimits.maxManifestBytes),
                key: nil
            )
            return ManifestParseResult(manifest: nil, issues: [issue])
        }
        let read = ManifestReader.read(text)
        var mapper = ManifestSchemaMapper(isTruncated: read.isTruncated)
        let manifest = mapper.map(read.root)
        // Stable sort: issues on the same line keep the order they were found in.
        let issues = (read.issues + mapper.issues).enumerated()
            .sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
            .map(\.element)
        return ManifestParseResult(manifest: manifest, issues: issues)
    }
}
