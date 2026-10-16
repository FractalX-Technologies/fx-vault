import VaultCore

/// How a manifest variable is stored.
public enum ManifestVarKind: String, Sendable, Hashable, CaseIterable {
    /// A plain variable (neither `secret:` nor `public:`).
    case variable
    /// `secret: true`: stored encrypted (a GitHub secret, a Key Vault secret, a sensitive
    /// Vercel variable).
    case secret
    /// `public: true`: a plain variable whose value may end up in client code.
    case publicVariable
}

/// One entry of `vars:` in `fxvault.yml`: a variable name, how it is stored, and where it goes.
///
/// Equality and hashing ignore ``line``: two variables are equal when they say the same thing,
/// wherever they were written.
public struct ManifestVarModel: Sendable, Hashable {
    /// The variable name, uppercase as GitHub stores it (``GitHubNameValidator``).
    public let name: String
    /// Secret, public or plain.
    public let kind: ManifestVarKind
    /// The target names it is sent to, in manifest order, without repeats.
    public let targets: [String]
    /// The stages it is used at (declared spellings), or nil for every stage.
    public let stages: [String]?
    /// 1-based line of the variable's name in the manifest, or 0 for a variable built in code.
    public let line: Int

    public init(
        name: String,
        kind: ManifestVarKind = .variable,
        targets: [String],
        stages: [String]? = nil,
        line: Int = 0
    ) {
        self.name = name
        self.kind = kind
        self.targets = targets
        self.stages = stages
        self.line = line
    }

    /// True for `secret: true`.
    public var isSecret: Bool {
        kind == .secret
    }

    /// True for `public: true`.
    public var isPublic: Bool {
        kind == .publicVariable
    }

    /// True when the variable is used at `stage` (compared case-insensitively). Does not check
    /// that `stage` is declared; ``ManifestModel/vars(for:)`` does.
    public func isUsed(at stage: String) -> Bool {
        guard let stages else { return true }
        let key = EnvironmentNameValidator.foldKey(stage)
        return stages.contains { EnvironmentNameValidator.foldKey($0) == key }
    }

    public static func == (lhs: ManifestVarModel, rhs: ManifestVarModel) -> Bool {
        lhs.name == rhs.name && lhs.kind == rhs.kind && lhs.targets == rhs.targets && lhs.stages == rhs.stages
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(kind)
        hasher.combine(targets)
        hasher.combine(stages)
    }
}
