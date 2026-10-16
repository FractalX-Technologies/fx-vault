/// Renders a `.env.example` for one manifest target: a header comment, then `NAME=` for every
/// variable the manifest sends there. Names only; values are never part of a manifest.
public enum ManifestEnvExample {
    private static let separator = " · "
    private static let everyStage = "every stage"
    private static let source = "from \(ManifestParser.fileName), names only"

    /// `# <target> (<provider>) · <stage> · from fxvault.yml, names only`, then one `NAME=` line
    /// per variable sent to `target` (only those used at `stage` when one is given), in manifest
    /// order, ending in a line break. An unknown target or undeclared stage lists no names.
    public static func render(_ manifest: ManifestModel, target: String, stage: String?) -> String {
        let model = manifest.target(named: target)
        let targetLabel = model.map { "\($0.name) (\($0.provider.rawValue))" } ?? commentSafe(target)
        let stageLabel = stage.map { manifest.stage(matching: $0) ?? commentSafe($0) } ?? everyStage
        let header = "# " + [targetLabel, stageLabel, source].joined(separator: separator)
        let names = model == nil ? [] : manifest.vars(sentTo: target, stage: stage).map { "\($0.name)=" }
        return ([header] + names).joined(separator: "\n") + "\n"
    }

    /// `text` on one comment line: line breaks and other control characters become spaces.
    private static func commentSafe(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
    }
}
