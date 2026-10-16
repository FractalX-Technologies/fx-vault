/// Writes `fxvault.yml` text that ``ManifestParser`` reads back to an equal model with no issues
/// (for any model the parser accepts).
///
/// The output is deterministic: a header comment, `version`, `stages`, then one line per target
/// and per variable in model order, in flow style with the values aligned after the longest
/// name. Fields that do not fit in ``maxLineWidth`` continue on the next line, aligned after the
/// opening brace. Per-stage mappings follow the manifest's stage order. Scalars stay plain when
/// that is unambiguous YAML and are quoted otherwise (single quotes; double quotes for line
/// breaks and tabs).
public enum ManifestSerializer {
    /// The first line of every rendered manifest.
    public static let headerComment = "# fxvault.yml · names and destinations, never values"
    /// Width, in characters, past which a target or variable is wrapped (local choice).
    public static let maxLineWidth = 100

    private static let indent = "  "
    /// Scalars that YAML parsers read as booleans or null, so they are quoted (compared in
    /// lowercase; YAML 1.1 included).
    private static let reservedWords: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "y", "n"]

    /// Renders `manifest` as `fxvault.yml` text, ending in a line break.
    public static func render(_ manifest: ManifestModel) -> String {
        var lines = [headerComment, "\(ManifestField.version): \(manifest.version)"]
        lines += flowSequence(prefix: "\(ManifestField.stages): ", items: manifest.stages.map(scalar))
        lines.append("")
        lines += section(
            ManifestField.targets,
            rows: manifest.targets.map { (scalar($0.name), targetFields($0, stages: manifest.stages)) }
        )
        lines.append("")
        lines += section(ManifestField.vars, rows: manifest.vars.map { (scalar($0.name), varFields($0)) })
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Sections

    /// `name:` then one aligned `key: { fields }` row per entry, or `name: {}`.
    private static func section(_ name: String, rows: [(key: String, fields: [String])]) -> [String] {
        guard !rows.isEmpty else { return ["\(name): {}"] }
        let width = rows.map(\.key.count).max() ?? 0
        var lines = ["\(name):"]
        for row in rows {
            let padding = String(repeating: " ", count: width - row.key.count + 1)
            lines += flowMapping(prefix: indent + row.key + ":" + padding, items: row.fields)
        }
        return lines
    }

    private static func targetFields(_ target: ManifestTargetModel, stages: [String]) -> [String] {
        var fields = [field(ManifestField.provider, target.provider.rawValue)]
        switch target.configuration {
        case .githubActions(let environment):
            if let environment {
                fields.append(field(ManifestField.environment, stageValue(environment, stages: stages, render: scalar)))
            }
        case .azureKeyVault(let vault):
            fields.append(field(ManifestField.vault, stageValue(vault, stages: stages, render: scalar)))
        case .supabase(let project):
            fields.append(field(ManifestField.project, stageValue(project, stages: stages, render: scalar)))
        case .vercel(let project, let team, let environment):
            fields.append(field(ManifestField.project, scalar(project)))
            if let team { fields.append(field(ManifestField.team, scalar(team))) }
            if let environment {
                let value = stageValue(environment, stages: stages) { scalar($0.rawValue) }
                fields.append(field(ManifestField.environment, value))
            }
        }
        return fields
    }

    private static func varFields(_ variable: ManifestVarModel) -> [String] {
        var fields: [String] = []
        switch variable.kind {
        case .secret: fields.append(field(ManifestField.secret, "true"))
        case .publicVariable: fields.append(field(ManifestField.isPublic, "true"))
        case .variable: break
        }
        fields.append(field(ManifestField.to, inlineSequence(variable.targets.map(scalar))))
        if let stages = variable.stages {
            fields.append(field(ManifestField.stages, inlineSequence(stages.map(scalar))))
        }
        return fields
    }

    /// One scalar, or `{ stage: value, ... }` in the manifest's stage order (stages the
    /// manifest does not declare, possible only in a model built in code, come last, sorted).
    private static func stageValue<Value>(
        _ value: ManifestStageValue<Value>,
        stages: [String],
        render: (Value) -> String
    ) -> String {
        switch value {
        case .everyStage(let single):
            return render(single)
        case .perStage(let values):
            let declared = stages.filter { values[$0] != nil }
            let others = values.keys.filter { !stages.contains($0) }.sorted()
            let items = (declared + others).compactMap { stage in
                values[stage].map { field(scalar(stage), render($0)) }
            }
            return items.isEmpty ? "{}" : "{ " + items.joined(separator: ", ") + " }"
        }
    }

    // MARK: - Layout

    private static func field(_ key: String, _ value: String) -> String {
        "\(key): \(value)"
    }

    private static func inlineSequence(_ items: [String]) -> String {
        "[" + items.joined(separator: ", ") + "]"
    }

    private static func flowMapping(prefix: String, items: [String]) -> [String] {
        guard !items.isEmpty else { return [prefix + "{}"] }
        return wrapped(prefix: prefix, open: "{ ", items: items, close: " }")
    }

    private static func flowSequence(prefix: String, items: [String]) -> [String] {
        guard !items.isEmpty else { return [prefix + "[]"] }
        return wrapped(prefix: prefix, open: "[", items: items, close: "]")
    }

    /// `prefix open a, b close`, filling each line up to ``maxLineWidth`` and continuing on lines
    /// aligned after `open`. An item longer than a line gets a line of its own.
    private static func wrapped(prefix: String, open: String, items: [String], close: String) -> [String] {
        let continuation = String(repeating: " ", count: prefix.count + open.count)
        var lines: [String] = []
        var current = prefix + open
        for (offset, item) in items.enumerated() {
            let trailer = offset == items.count - 1 ? close : ","
            let candidate = offset == 0 ? current + item : current + ", " + item
            if offset == 0 || candidate.count + trailer.count <= maxLineWidth {
                current = candidate
            } else {
                lines.append(current + ",")
                current = continuation + item
            }
        }
        lines.append(current + close)
        return lines
    }

    // MARK: - Scalars

    /// `text` as a YAML scalar: plain when it starts with an ASCII letter or `_`, holds only
    /// `[A-Za-z0-9_.-]` and is not a reserved word; double-quoted when it holds a line break or
    /// tab; single-quoted otherwise.
    static func scalar(_ text: String) -> String {
        if isPlainSafe(text) { return text }
        if text.contains(where: { $0 == "\n" || $0 == "\t" }) {
            var quoted = "\""
            for character in text {
                switch character {
                case "\"": quoted += "\\\""
                case "\\": quoted += "\\\\"
                case "\n": quoted += "\\n"
                case "\t": quoted += "\\t"
                default: quoted.append(character)
                }
            }
            return quoted + "\""
        }
        var quoted = "'"
        for character in text {
            quoted.append(character)
            if character == "'" { quoted.append("'") }
        }
        return quoted + "'"
    }

    private static func isPlainSafe(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let first = bytes.first, ASCII.isLetter(first) || first == ASCII.underscore else { return false }
        guard !reservedWords.contains(text.lowercased()) else { return false }
        return bytes.allSatisfy {
            ASCII.isAlphanumeric($0) || $0 == ASCII.underscore || $0 == ASCII.period || $0 == ASCII.hyphen
        }
    }
}
