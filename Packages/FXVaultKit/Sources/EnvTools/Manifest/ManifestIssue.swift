import VaultCore

/// A problem found in an `fxvault.yml` manifest (``ManifestParser``), tied to a 1-based line.
///
/// Issues carry no localized text; the app maps them. ``key`` and every string inside a
/// ``Kind`` are names written in the manifest (stages, targets, variables, fields), never values,
/// with control, bidi, zero-width and invisible characters removed. Issues that concern the
/// whole file (``Kind/fileTooLarge(limit:)``, ``Kind/emptyManifest``) use line 1.
public struct ManifestIssue: Sendable, Hashable {
    /// What went wrong. Reader kinds come first (the YAML subset), then schema kinds.
    ///
    /// Unless a case says otherwise, the entry the issue names is left out of the
    /// ``ManifestModel``: a broken per-stage value leaves the target unused at that stage, a
    /// broken target or variable is dropped, and a broken required top-level field (or an
    /// exceeded limit) leaves ``ManifestParseResult/manifest`` nil.
    public enum Kind: Sendable, Hashable {
        // MARK: Reader

        /// The file is larger than ``EnvToolsLimits/maxManifestBytes``. Nothing was read.
        case fileTooLarge(limit: Int)
        /// The line's indentation contains a tab; only spaces indent. The line was skipped.
        case tabInIndentation
        /// A YAML feature outside the supported subset (see ``Construct``).
        case unsupported(Construct)
        /// A quoted scalar does not close on its line (quoted scalars never span lines).
        case unterminatedQuote
        /// A double-quoted scalar uses an escape other than `\"`, `\\`, `\n` or `\t`.
        case invalidEscapeSequence
        /// A `[` or `{` is never closed. The rest of the file belongs to it.
        case unterminatedFlowCollection
        /// Something that is not allowed where it appears: a stray `]`, `}` or `,`, text after a
        /// closing quote or a flow collection, a second `key:` on one line, or a reserved
        /// character (`@`, `` ` ``, `%`).
        case unexpectedContent
        /// A line inside a block mapping is not `key: value`.
        case missingColon
        /// A line is indented deeper than its block allows, or back to a column no open block
        /// uses. The line and the lines nested under it were skipped.
        case invalidIndentation
        /// A `- item` where a `key:` is expected, or a `key:` where a `- item` is expected.
        case mixedCollection
        /// A mapping key is a flow collection or empty; keys must be plain or quoted scalars.
        case nonScalarKey
        /// The same key appears twice in one mapping. The first one, on `previousLine`, is
        /// kept. ``ManifestIssue/key`` is the repeated key.
        case duplicateKey(previousLine: Int)
        /// Mappings and sequences nest deeper than ``EnvToolsLimits/maxManifestNestingDepth``.
        case nestingTooDeep(limit: Int)

        // MARK: Document

        /// The file holds no content (empty, or only comments and blank lines).
        case emptyManifest
        /// A value has the wrong type. `field` is the field holding it (nil for the document
        /// itself or for a target or variable body).
        case wrongType(field: String?, expected: ValueType)
        /// A required field is missing.
        case missingField(String)
        /// A field FX Vault does not know. Warning: the field was ignored.
        case unknownField(String)
        /// `version` is not 1.
        case unsupportedVersion

        // MARK: Stages

        /// A stage list (`stages: []`, top-level or in a variable) is empty.
        case noStages
        /// More than ``EnvToolsLimits/maxManifestStages`` stages.
        case tooManyStages(limit: Int)
        /// The stage name breaks a GitHub environment name rule.
        case invalidStageName(ValidationError)
        /// The stage was already declared (stage names compare case-insensitively).
        case duplicateStage
        /// A per-stage mapping or a variable's `stages` names a stage `stages` does not declare.
        case undeclaredStage(String)

        // MARK: Targets

        /// More than ``EnvToolsLimits/maxManifestTargets`` targets.
        case tooManyTargets(limit: Int)
        /// The target name is not `[a-z][a-z0-9-]{0,31}`.
        case invalidTargetName
        /// `provider` is not one of ``ManifestProvider``.
        case unknownProvider
        /// Not a valid Azure Key Vault name (for `stage`, or for every stage when nil).
        case invalidVaultName(stage: String?)
        /// Not a Supabase project ref: 20 lowercase letters (for `stage`, or every stage).
        case invalidProjectRef(stage: String?)
        /// Not a Vercel project name or `prj_` id.
        case invalidVercelProject
        /// Not a Vercel team slug or `team_` id.
        case invalidVercelTeam
        /// Not `production`, `preview` or `development` (for `stage`, or every stage).
        case invalidVercelEnvironment(stage: String?)
        /// The GitHub environment name breaks a rule (for `stage`, or every stage).
        case invalidGitHubEnvironment(ValidationError, stage: String?)

        // MARK: Variables

        /// More than ``EnvToolsLimits/maxManifestVars`` variables.
        case tooManyVars(limit: Int)
        /// The variable name breaks a GitHub secret and variable name rule.
        case invalidVarName(NameRule)
        /// The variable name has lowercase letters; manifest names are written as GitHub stores
        /// them (uppercase), because Vercel and Supabase names are case-sensitive.
        case varNameNotUppercase
        /// `secret: true` and `public: true` together.
        case secretAndPublic
        /// `to: []`: the variable goes nowhere.
        case noTargets
        /// `to` names a target `targets` does not define. Only that reference is dropped.
        case undefinedTarget(String)
        /// A name appears twice in one `to` or `stages` list, or a stage twice in a per-stage
        /// mapping. Warning: the repeat was ignored.
        case duplicateReference(String)
        /// A secret sent to a Vercel target has a public prefix (`NEXT_PUBLIC_`, see
        /// ``PublicNamePrefixes``), so the framework would inline it into client code. The
        /// variable is kept, so checks can show it as blocked.
        case publicPrefixOnSecret(prefix: String)
        /// A variable sent to a Supabase target starts with `SUPABASE_`, which Supabase reserves
        /// for its own Edge Function secrets. The variable is kept, so checks can show it as
        /// blocked.
        case reservedSupabasePrefix
    }

    /// A YAML feature the manifest subset does not support.
    public enum Construct: Sendable, Hashable, CaseIterable {
        /// `&name`. The anchor is ignored and its node read.
        case anchor
        /// `*name`.
        case alias
        /// `!tag` or `!!type`. The tag is ignored and its node read.
        case tag
        /// `|` or `>`. The scalar's lines were skipped.
        case blockScalar
        /// A second document (`---` after content, or anything after `...`). It was not read.
        case multipleDocuments
        /// `? key`. The entry was skipped.
        case complexKey
        /// `%YAML` or `%TAG`. The line was skipped.
        case directive
    }

    /// The type a field expects (``Kind/wrongType(field:expected:)``).
    public enum ValueType: Sendable, Hashable, CaseIterable {
        /// `key: value` lines or `{ key: value }`.
        case mapping
        /// `- item` lines or `[a, b]`.
        case sequence
        /// A plain or quoted scalar.
        case text
        /// `true` or `false`, unquoted.
        case boolean
        /// An unquoted decimal integer.
        case integer
        /// One scalar for every stage, or a `{ stage: value }` mapping.
        case textOrMapping
    }

    /// How serious the issue is.
    public enum Severity: Sendable, Hashable {
        /// The manifest was understood; something was ignored.
        case warning
        /// The manifest is wrong; see ``Kind`` for what was left out of the model.
        case error
    }

    /// 1-based line of the problem (the line of the key, entry or value concerned).
    public let line: Int
    /// What went wrong.
    public let kind: Kind
    /// The stage, target or variable the issue is about, or the repeated key for
    /// ``Kind/duplicateKey(previousLine:)``. Nil for document-level issues. Never a value.
    public let key: String?

    public init(line: Int, kind: Kind, key: String?) {
        self.line = line
        self.kind = kind
        self.key = key
    }

    /// ``Severity/warning`` for ignored fields and repeated references, ``Severity/error``
    /// for everything else.
    public var severity: Severity {
        switch kind {
        case .unknownField, .duplicateReference:
            .warning
        default:
            .error
        }
    }
}

extension ManifestIssue {
    /// An issue whose names are safe to show: control, bidi, zero-width and invisible
    /// characters are removed from `key` and from the names inside `kind` (a manifest is text
    /// written by someone else).
    static func sanitized(line: Int, kind: Kind, key: String?) -> ManifestIssue {
        ManifestIssue(line: line, kind: kind.sanitized, key: key.map(displayName))
    }

    static func displayName(_ name: String) -> String {
        UnicodeScalarPolicy.removingDisallowedAndInvisible(from: name)
    }
}

extension ManifestIssue.Kind {
    /// The kind with every manifest-written name passed through ``ManifestIssue/displayName(_:)``.
    var sanitized: Self {
        switch self {
        case .wrongType(let field, let expected):
            .wrongType(field: field.map(ManifestIssue.displayName), expected: expected)
        case .missingField(let field):
            .missingField(ManifestIssue.displayName(field))
        case .unknownField(let field):
            .unknownField(ManifestIssue.displayName(field))
        case .undeclaredStage(let stage):
            .undeclaredStage(ManifestIssue.displayName(stage))
        case .invalidVaultName(let stage):
            .invalidVaultName(stage: stage.map(ManifestIssue.displayName))
        case .invalidProjectRef(let stage):
            .invalidProjectRef(stage: stage.map(ManifestIssue.displayName))
        case .invalidVercelEnvironment(let stage):
            .invalidVercelEnvironment(stage: stage.map(ManifestIssue.displayName))
        case .invalidGitHubEnvironment(let error, let stage):
            .invalidGitHubEnvironment(error, stage: stage.map(ManifestIssue.displayName))
        case .undefinedTarget(let target):
            .undefinedTarget(ManifestIssue.displayName(target))
        case .duplicateReference(let name):
            .duplicateReference(ManifestIssue.displayName(name))
        default:
            self
        }
    }
}
