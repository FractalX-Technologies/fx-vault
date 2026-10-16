import VaultCore

/// A parsed `fxvault.yml`: the stages a project deploys to, the targets (destinations) its
/// variables go to, and the variables themselves, by name only. The manifest never holds values.
public struct ManifestModel: Sendable, Hashable {
    /// The only manifest version this build reads and writes.
    public static let currentVersion = 1

    /// The manifest format version (``currentVersion``).
    public let version: Int
    /// Declared stages in manifest order (NFC; unique case-insensitively).
    public let stages: [String]
    /// Targets in manifest order (unique names).
    public let targets: [ManifestTargetModel]
    /// Variables in manifest order (unique names).
    public let vars: [ManifestVarModel]

    public init(
        version: Int = ManifestModel.currentVersion,
        stages: [String],
        targets: [ManifestTargetModel],
        vars: [ManifestVarModel]
    ) {
        self.version = version
        self.stages = stages
        self.targets = targets
        self.vars = vars
    }

    /// The target named `name`, or nil.
    public func target(named name: String) -> ManifestTargetModel? {
        targets.first { $0.name == name }
    }

    /// The declared spelling of `stage` (compared case-insensitively), or nil when the manifest
    /// does not declare it.
    public func stage(matching stage: String) -> String? {
        let key = EnvironmentNameValidator.foldKey(stage)
        return stages.first { EnvironmentNameValidator.foldKey($0) == key }
    }

    /// The variables used at `stage` (compared case-insensitively), in manifest order. Empty
    /// when the stage is not declared.
    public func vars(for stage: String) -> [ManifestVarModel] {
        guard let declared = self.stage(matching: stage) else { return [] }
        return vars.filter { $0.isUsed(at: declared) }
    }

    /// The variables sent to `target`, in manifest order; only those used at `stage` when one
    /// is given (empty when that stage is not declared).
    public func vars(sentTo target: String, stage: String? = nil) -> [ManifestVarModel] {
        let candidates = stage.map(vars(for:)) ?? vars
        return candidates.filter { $0.targets.contains(target) }
    }

    /// Where `target` sends variables at `stage`, or nil when the target is unknown, the stage
    /// is not declared, or the target is not used at that stage.
    public func location(of target: String, at stage: String) -> ManifestLocation? {
        guard let declared = self.stage(matching: stage), let model = self.target(named: target) else {
            return nil
        }
        return model.location(for: declared)
    }
}

/// The output of ``ManifestParser/parse(_:)``: the manifest when the document produced a
/// coherent one, and every issue found, ordered by line.
public struct ManifestParseResult: Sendable, Hashable {
    /// The manifest, or nil when the file is too large, empty, of another version, or missing
    /// (or breaking) a required top-level field. Entries with errors are left out of it.
    public let manifest: ManifestModel?
    /// Every issue, ordered by line (issues on one line keep the order they were found in).
    public let issues: [ManifestIssue]

    public init(manifest: ManifestModel?, issues: [ManifestIssue]) {
        self.manifest = manifest
        self.issues = issues
    }

    /// True when at least one issue is an error.
    public var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }

    /// Issues for one line.
    public func issues(onLine line: Int) -> [ManifestIssue] {
        issues.filter { $0.line == line }
    }
}
