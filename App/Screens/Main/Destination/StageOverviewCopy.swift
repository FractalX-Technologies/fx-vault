import EnvTools
import Foundation
import VaultCore
import VaultData

/// The text of the Overview and the `fxvault.yml` check (v0.8.0). Names only.
nonisolated enum StageOverviewCopy {
    static var eyebrow: String {
        String(localized: "overview.eyebrow", defaultValue: "Stage · All destinations")
    }

    static var stagePicker: String {
        String(localized: "overview.stage", defaultValue: "Stage")
    }

    static var githubColumn: String {
        String(localized: "overview.column.github", defaultValue: "GitHub")
    }

    static var repositoryLevel: String {
        String(localized: "overview.column.repositoryLevel", defaultValue: "Repository")
    }

    static var nameColumn: String {
        String(localized: "overview.column.name", defaultValue: "Name")
    }

    static var cycleColumn: String {
        String(localized: "overview.column.cycle", defaultValue: "Cycle")
    }

    static func destinations(_ count: Int) -> String {
        count == 1
            ? String(localized: "overview.destinations.one", defaultValue: "1 destination")
            : String(localized: "overview.destinations", defaultValue: "\(count) destinations")
    }

    static var noStages: String {
        String(
            localized: "overview.noStages",
            defaultValue: "Add a destination with a stage, or an environment, to see a stage across GitHub and its destinations."
        )
    }

    static var legend: String {
        String(
            localized: "overview.legend",
            defaultValue: "Missing: fxvault.yml sends the name here. Extra: here, but fxvault.yml does not send it here. Differs: another place of this stage holds another value. Blocked: a public name with a secret-looking value. —: not used here."
        )
    }

    static func cycle(_ cycle: StageOverviewCycle) -> String {
        switch cycle {
        case .runtime: String(localized: "overview.cycle.runtime", defaultValue: "Runtime")
        case .publicValue: String(localized: "overview.cycle.public", defaultValue: "Public")
        case .build: String(localized: "overview.cycle.build", defaultValue: "Build")
        case .unknown: "—"
        }
    }

    static func cell(_ cell: StageOverviewCellModel) -> String {
        switch cell {
        case .notUsed: "—"
        case .synced: String(localized: "overview.cell.synced", defaultValue: "Synced")
        case .willPush: String(localized: "overview.cell.willPush", defaultValue: "Will push")
        case .willDelete: String(localized: "overview.cell.willDelete", defaultValue: "Will delete")
        case .valueMissing: String(localized: "overview.cell.valueMissing", defaultValue: "Value missing")
        case .missing: String(localized: "overview.cell.missing", defaultValue: "Missing")
        case .extra: String(localized: "overview.cell.extra", defaultValue: "Extra")
        case .differs: String(localized: "overview.cell.differs", defaultValue: "Differs")
        case .blocked: String(localized: "overview.cell.blocked", defaultValue: "Blocked")
        }
    }

    // MARK: Manifest

    static var manifestTitle: String {
        String(localized: "overview.manifest.title", defaultValue: "fxvault.yml")
    }

    static func manifestState(_ state: ManifestStateModel?, isReading: Bool) -> String {
        if isReading {
            return String(localized: "overview.manifest.reading", defaultValue: "Reading fxvault.yml…")
        }
        return switch state {
        case .none?:
            String(localized: "overview.manifest.none", defaultValue: "No fxvault.yml in the repository")
        case .read(_, let result)?:
            result.manifest == nil
                ? String(localized: "overview.manifest.invalid", defaultValue: "fxvault.yml has errors")
                : String(localized: "overview.manifest.read", defaultValue: "fxvault.yml on the default branch")
        case .unavailable?, nil:
            String(localized: "overview.manifest.unavailable", defaultValue: "fxvault.yml could not be read")
        }
    }

    static var readAgain: String {
        String(localized: "overview.manifest.readAgain", defaultValue: "Read Again")
    }

    static var showCheck: String {
        String(localized: "overview.manifest.show", defaultValue: "Show Check")
    }

    static var hideCheck: String {
        String(localized: "overview.manifest.hide", defaultValue: "Hide Check")
    }

    /// The banner names `fxvault.yml` only when a manifest was applied: public names with a
    /// secret-looking value are findings without one.
    static func findingsBanner(_ count: Int, stage: String, usesManifest: Bool) -> String {
        switch (count == 1, usesManifest) {
        case (true, true):
            String(localized: "overview.findings.banner.one", defaultValue: "1 thing to fix in \(stage), by fxvault.yml")
        case (false, true):
            String(localized: "overview.findings.banner", defaultValue: "\(count) things to fix in \(stage), by fxvault.yml")
        case (true, false):
            String(localized: "overview.findings.banner.noManifest.one", defaultValue: "1 thing to fix in \(stage)")
        case (false, false):
            String(localized: "overview.findings.banner.noManifest", defaultValue: "\(count) things to fix in \(stage)")
        }
    }

    static var noFindings: String {
        String(localized: "overview.findings.none", defaultValue: "This stage matches fxvault.yml.")
    }

    static var copyDraft: String {
        String(localized: "overview.manifest.copyDraft", defaultValue: "Copy fxvault.yml for This Repository")
    }

    static var copyDraftHelp: String {
        String(
            localized: "overview.manifest.copyDraft.help",
            defaultValue: "Copy an fxvault.yml that describes this repository now (names only), to commit at its root"
        )
    }

    static var draftCopied: String {
        String(
            localized: "overview.manifest.draftCopied",
            defaultValue: "Copied fxvault.yml. Commit it at the root of the repository; FX Vault reads it from the default branch."
        )
    }

    static var copyExample: String {
        String(localized: "overview.manifest.copyExample", defaultValue: "Copy .env.example")
    }

    static func exampleCopied(_ target: String) -> String {
        String(localized: "overview.manifest.exampleCopied", defaultValue: "Copied the .env.example for \(target).")
    }

    static var addDestination: String {
        String(localized: "overview.finding.addDestination", defaultValue: "Add Destination")
    }

    static func finding(_ finding: StageOverviewFindingModel, column: (String) -> String) -> String {
        switch finding {
        case .missing(let name, let id):
            String(localized: "overview.finding.missing", defaultValue: "\(name) is in fxvault.yml for \(column(id)), which does not have it.")
        case .extra(let name, let id):
            String(localized: "overview.finding.extra", defaultValue: "\(name) is in \(column(id)), but fxvault.yml does not send it there.")
        case .blocked(let name, let id):
            String(
                localized: "overview.finding.blocked",
                defaultValue: "\(name) in \(column(id)) is public, and its value looks like a secret. Change the value, or Mark as Public."
            )
        case .kindMismatch(let name, let id):
            String(localized: "overview.finding.kind", defaultValue: "\(name) is a secret in fxvault.yml, but a variable in \(column(id)).")
        case .destinationNotAdded(let target, let location):
            String(
                localized: "overview.finding.destination",
                defaultValue: "fxvault.yml sends names to \(target) (\(describe(location))), which this repository has no destination for."
            )
        }
    }

    static func describe(_ location: ManifestLocation) -> String {
        switch location {
        case .githubEnvironment(let name): "GitHub · \(name)"
        case .keyVault(let vaultName): "Key Vault · \(vaultName)"
        case .supabase(let projectRef): "Supabase · \(projectRef)"
        case .vercel(let project, _, let environment): "Vercel · \(project) · \(environment.rawValue)"
        }
    }

    static func issueLine(_ issue: ManifestIssue) -> String {
        String(localized: "overview.issue.line", defaultValue: "Line \(issue.line)")
    }

    /// One parse issue, in a sentence. Names only (``ManifestIssue/key`` and names inside the kind).
    static func issue(_ issue: ManifestIssue) -> String {
        let key = issue.key ?? ""
        switch issue.kind {
        case .fileTooLarge(let limit):
            return String(localized: "manifest.issue.fileTooLarge", defaultValue: "The file is larger than \(limit) bytes.")
        case .tabInIndentation:
            return String(localized: "manifest.issue.tab", defaultValue: "Indent with spaces, not tabs.")
        case .unsupported(let construct):
            return String(localized: "manifest.issue.unsupported", defaultValue: "fxvault.yml does not support \(describe(construct)).")
        case .unterminatedQuote:
            return String(localized: "manifest.issue.unterminatedQuote", defaultValue: "A quoted value does not close on its line.")
        case .invalidEscapeSequence:
            return String(localized: "manifest.issue.escape", defaultValue: "Only \\\", \\\\, \\n and \\t escapes are supported.")
        case .unterminatedFlowCollection:
            return String(localized: "manifest.issue.unterminatedFlow", defaultValue: "A [ or { is never closed.")
        case .unexpectedContent:
            return String(localized: "manifest.issue.unexpected", defaultValue: "Something here is not allowed.")
        case .missingColon:
            return String(localized: "manifest.issue.missingColon", defaultValue: "Write this line as key: value.")
        case .invalidIndentation:
            return String(localized: "manifest.issue.indentation", defaultValue: "This line is not indented like its block.")
        case .mixedCollection:
            return String(localized: "manifest.issue.mixed", defaultValue: "A list item and a key: value are mixed here.")
        case .nonScalarKey:
            return String(localized: "manifest.issue.nonScalarKey", defaultValue: "Keys must be plain or quoted names.")
        case .duplicateKey(let previousLine):
            return String(localized: "manifest.issue.duplicateKey", defaultValue: "\(key) is already on line \(previousLine).")
        case .nestingTooDeep(let limit):
            return String(localized: "manifest.issue.nesting", defaultValue: "Values nest deeper than \(limit) levels.")
        case .emptyManifest:
            return String(localized: "manifest.issue.empty", defaultValue: "The file is empty.")
        case .wrongType(let field, let expected):
            return String(
                localized: "manifest.issue.wrongType",
                defaultValue: "\(field ?? key) should be \(describe(expected))."
            )
        case .missingField(let field):
            return String(localized: "manifest.issue.missingField", defaultValue: "\(key.isEmpty ? field : key) needs \(field).")
        case .unknownField(let field):
            return String(localized: "manifest.issue.unknownField", defaultValue: "\(field) is not a field FX Vault knows; it was ignored.")
        case .unsupportedVersion:
            return String(localized: "manifest.issue.version", defaultValue: "Only version: 1 is supported.")
        case .noStages:
            return String(localized: "manifest.issue.noStages", defaultValue: "List at least one stage.")
        case .tooManyStages(let limit):
            return String(localized: "manifest.issue.tooManyStages", defaultValue: "Use at most \(limit) stages.")
        case .invalidStageName(let error):
            return String(localized: "manifest.issue.stageName", defaultValue: "Stage \(key): \(error.localizedMessage)")
        case .duplicateStage:
            return String(localized: "manifest.issue.duplicateStage", defaultValue: "Stage \(key) is listed twice.")
        case .undeclaredStage(let stage):
            return String(localized: "manifest.issue.undeclaredStage", defaultValue: "\(stage) is not in stages.")
        case .tooManyTargets(let limit):
            return String(localized: "manifest.issue.tooManyTargets", defaultValue: "Use at most \(limit) targets.")
        case .invalidTargetName:
            return String(
                localized: "manifest.issue.targetName",
                defaultValue: "Target \(key): use lowercase letters, digits and dashes, starting with a letter."
            )
        case .unknownProvider:
            return String(
                localized: "manifest.issue.provider",
                defaultValue: "Target \(key): provider is github-actions, azure-keyvault, supabase or vercel."
            )
        case .invalidVaultName:
            return String(localized: "manifest.issue.vault", defaultValue: "Target \(key): \(DestinationTargetRule.keyVaultName.localizedMessage)")
        case .invalidProjectRef:
            return String(localized: "manifest.issue.projectRef", defaultValue: "Target \(key): \(DestinationTargetRule.supabaseProjectRef.localizedMessage)")
        case .invalidVercelProject:
            return String(localized: "manifest.issue.vercelProject", defaultValue: "Target \(key): project is a Vercel project name or prj_ id.")
        case .invalidVercelTeam:
            return String(localized: "manifest.issue.vercelTeam", defaultValue: "Target \(key): team is a Vercel team slug or team_ id.")
        case .invalidVercelEnvironment:
            return String(
                localized: "manifest.issue.vercelEnvironment",
                defaultValue: "Target \(key): environment is production, preview or development."
            )
        case .invalidGitHubEnvironment(let error, _):
            return String(localized: "manifest.issue.githubEnvironment", defaultValue: "Target \(key): \(error.localizedMessage)")
        case .tooManyVars(let limit):
            return String(localized: "manifest.issue.tooManyVars", defaultValue: "Use at most \(limit) vars.")
        case .invalidVarName(let rule):
            return String(localized: "manifest.issue.varName", defaultValue: "\(key): \(rule.localizedMessage)")
        case .varNameNotUppercase:
            return String(localized: "manifest.issue.varUppercase", defaultValue: "\(key): write names in uppercase, as GitHub stores them.")
        case .secretAndPublic:
            return String(localized: "manifest.issue.secretAndPublic", defaultValue: "\(key) cannot be both secret and public.")
        case .noTargets:
            return String(localized: "manifest.issue.noTargets", defaultValue: "\(key) needs at least one target in to.")
        case .undefinedTarget(let target):
            return String(localized: "manifest.issue.undefinedTarget", defaultValue: "\(key): \(target) is not in targets.")
        case .duplicateReference(let name):
            return String(localized: "manifest.issue.duplicateReference", defaultValue: "\(name) is listed twice; the repeat was ignored.")
        case .publicPrefixOnSecret(let prefix):
            return String(
                localized: "manifest.issue.publicPrefix",
                defaultValue: "\(key) is a secret, but \(prefix) names are public in the browser."
            )
        case .reservedSupabasePrefix:
            return String(localized: "manifest.issue.supabasePrefix", defaultValue: "\(key): names starting with SUPABASE_ are reserved by Supabase.")
        }
    }

    private static func describe(_ construct: ManifestIssue.Construct) -> String {
        switch construct {
        case .anchor: String(localized: "manifest.construct.anchor", defaultValue: "anchors (&)")
        case .alias: String(localized: "manifest.construct.alias", defaultValue: "aliases (*)")
        case .tag: String(localized: "manifest.construct.tag", defaultValue: "tags (!)")
        case .blockScalar: String(localized: "manifest.construct.blockScalar", defaultValue: "block values (| and >)")
        case .multipleDocuments: String(localized: "manifest.construct.documents", defaultValue: "several documents")
        case .complexKey: String(localized: "manifest.construct.complexKey", defaultValue: "complex keys (?)")
        case .directive: String(localized: "manifest.construct.directive", defaultValue: "directives (%)")
        }
    }

    private static func describe(_ type: ManifestIssue.ValueType) -> String {
        switch type {
        case .mapping: String(localized: "manifest.type.mapping", defaultValue: "a mapping")
        case .sequence: String(localized: "manifest.type.sequence", defaultValue: "a list")
        case .text: String(localized: "manifest.type.text", defaultValue: "text")
        case .boolean: String(localized: "manifest.type.boolean", defaultValue: "true or false")
        case .integer: String(localized: "manifest.type.integer", defaultValue: "a number")
        case .textOrMapping: String(localized: "manifest.type.textOrMapping", defaultValue: "text or a per-stage mapping")
        }
    }
}
