import VaultCore

/// Where a target's variables go (`provider:` in `fxvault.yml`).
public enum ManifestProvider: String, Sendable, Hashable, CaseIterable {
    /// GitHub Actions secrets and variables of a repository environment.
    case githubActions = "github-actions"
    /// Azure Key Vault secrets.
    case azureKeyVault = "azure-keyvault"
    /// Supabase Edge Function secrets.
    case supabase
    /// Vercel project environment variables.
    case vercel

    /// The fields a target of this provider may hold, `provider` included. Others are reported
    /// as ``ManifestIssue/Kind/unknownField(_:)``.
    var fieldNames: Set<String> {
        switch self {
        case .githubActions:
            [ManifestField.provider, ManifestField.environment]
        case .azureKeyVault:
            [ManifestField.provider, ManifestField.vault]
        case .supabase:
            [ManifestField.provider, ManifestField.project]
        case .vercel:
            [ManifestField.provider, ManifestField.project, ManifestField.team, ManifestField.environment]
        }
    }
}

/// A Vercel deployment environment.
public enum ManifestVercelEnvironment: String, Sendable, Hashable, CaseIterable {
    case production
    case preview
    case development

    /// The environment a stage uses when the target has no `environment:` field: `production`
    /// for a stage named "production" and `development` for "development" (compared
    /// case-insensitively), `preview` for every other stage.
    public static func defaultEnvironment(forStage stage: String) -> ManifestVercelEnvironment {
        switch EnvironmentNameValidator.foldKey(stage) {
        case ManifestVercelEnvironment.production.rawValue:
            .production
        case ManifestVercelEnvironment.development.rawValue:
            .development
        default:
            .preview
        }
    }
}

/// A target setting that is either one value for every stage (`vault: kv-one`) or a per-stage
/// mapping (`vault: { production: kv-a, staging: kv-b }`).
///
/// A stage missing from a per-stage mapping means the target is not used at that stage.
/// Per-stage keys are the manifest's declared stage spellings; lookups compare stage names
/// case-insensitively (``EnvironmentNameValidator/foldKey(_:)``).
public enum ManifestStageValue<Value: Sendable & Hashable>: Sendable, Hashable {
    /// The same value at every stage.
    case everyStage(Value)
    /// A value per stage; stages without an entry do not use the target.
    case perStage([String: Value])

    /// The value at `stage`, or nil when the target is not used there.
    public func value(for stage: String) -> Value? {
        switch self {
        case .everyStage(let value):
            return value
        case .perStage(let values):
            if let exact = values[stage] { return exact }
            let key = EnvironmentNameValidator.foldKey(stage)
            return values.first { EnvironmentNameValidator.foldKey($0.key) == key }?.value
        }
    }
}

/// A target's provider and its provider-specific settings.
public enum ManifestTargetConfiguration: Sendable, Hashable {
    /// GitHub Actions. `environment` maps stages to GitHub environment names; nil means every
    /// stage uses the environment named like the stage.
    case githubActions(environment: ManifestStageValue<String>?)
    /// Azure Key Vault: the vault name for each stage.
    case azureKeyVault(vault: ManifestStageValue<String>)
    /// Supabase: the project ref for each stage.
    case supabase(project: ManifestStageValue<String>)
    /// Vercel: one project (and optional team) for every stage. `environment` maps stages to
    /// Vercel environments; nil means ``ManifestVercelEnvironment/defaultEnvironment(forStage:)``.
    case vercel(project: String, team: String?, environment: ManifestStageValue<ManifestVercelEnvironment>?)

    /// The provider these settings belong to.
    public var provider: ManifestProvider {
        switch self {
        case .githubActions: .githubActions
        case .azureKeyVault: .azureKeyVault
        case .supabase: .supabase
        case .vercel: .vercel
        }
    }
}

/// The concrete place a target sends variables to at one stage.
public enum ManifestLocation: Sendable, Hashable {
    /// A GitHub Actions environment of the repository.
    case githubEnvironment(String)
    /// An Azure Key Vault.
    case keyVault(vaultName: String)
    /// A Supabase project's Edge Function secrets.
    case supabase(projectRef: String)
    /// A Vercel project's environment.
    case vercel(project: String, team: String?, environment: ManifestVercelEnvironment)
}

/// One entry of `targets:` in `fxvault.yml`: a named destination.
///
/// Equality and hashing ignore ``line``: two targets are equal when they describe the same
/// destination, wherever they were written.
public struct ManifestTargetModel: Sendable, Hashable {
    /// The target name (`[a-z][a-z0-9-]{0,31}`), used in a variable's `to:` list.
    public let name: String
    /// The provider and its settings.
    public let configuration: ManifestTargetConfiguration
    /// 1-based line of the target's name in the manifest, or 0 for a target built in code.
    public let line: Int

    public init(name: String, configuration: ManifestTargetConfiguration, line: Int = 0) {
        self.name = name
        self.configuration = configuration
        self.line = line
    }

    /// The provider the target sends to.
    public var provider: ManifestProvider {
        configuration.provider
    }

    /// Where the target sends variables at `stage`, or nil when the target is not used there.
    /// Expects one of the manifest's stages (see ``ManifestModel/location(of:at:)``, which
    /// checks it).
    public func location(for stage: String) -> ManifestLocation? {
        switch configuration {
        case .githubActions(let environment):
            guard let environment else { return .githubEnvironment(stage) }
            return environment.value(for: stage).map(ManifestLocation.githubEnvironment)
        case .azureKeyVault(let vault):
            return vault.value(for: stage).map { .keyVault(vaultName: $0) }
        case .supabase(let project):
            return project.value(for: stage).map { .supabase(projectRef: $0) }
        case .vercel(let project, let team, let environment):
            let resolved: ManifestVercelEnvironment?
            if let environment {
                resolved = environment.value(for: stage)
            } else {
                resolved = .defaultEnvironment(forStage: stage)
            }
            return resolved.map { .vercel(project: project, team: team, environment: $0) }
        }
    }

    public static func == (lhs: ManifestTargetModel, rhs: ManifestTargetModel) -> Bool {
        lhs.name == rhs.name && lhs.configuration == rhs.configuration
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(configuration)
    }
}

/// Field names of `fxvault.yml`, shared by the schema mapper and the serializer.
enum ManifestField {
    static let version = "version"
    static let stages = "stages"
    static let targets = "targets"
    static let vars = "vars"
    static let provider = "provider"
    static let environment = "environment"
    static let vault = "vault"
    static let project = "project"
    static let team = "team"
    static let secret = "secret"
    static let isPublic = "public"
    static let to = "to"

    /// The top-level fields.
    static let topLevel: Set<String> = [version, stages, targets, vars]
    /// The fields of a variable.
    static let variable: Set<String> = [secret, isPublic, to, stages]
}
