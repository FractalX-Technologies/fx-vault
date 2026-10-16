import VaultCore

/// Display text and symbols of runtime destinations (v0.8.0).
nonisolated extension DestinationProvider {
    /// "Azure Key Vault", "Supabase", "Vercel".
    var title: String {
        switch self {
        case .azureKeyVault: String(localized: "destination.provider.keyVault", defaultValue: "Azure Key Vault")
        case .supabase: String(localized: "destination.provider.supabase", defaultValue: "Supabase")
        case .vercel: String(localized: "destination.provider.vercel", defaultValue: "Vercel")
        }
    }

    /// A short form for chips and copy targets ("Key Vault").
    var shortTitle: String {
        switch self {
        case .azureKeyVault: String(localized: "destination.provider.keyVault.short", defaultValue: "Key Vault")
        case .supabase: title
        case .vercel: title
        }
    }

    /// The SF Symbol of the RUNTIME rows.
    var symbolName: String {
        switch self {
        case .azureKeyVault: "key"
        case .supabase: "server.rack"
        case .vercel: "globe"
        }
    }

    /// How FX Vault reaches the provider, for the review and the detail header.
    var accessDescription: String {
        switch self {
        case .azureKeyVault: String(localized: "destination.access.az", defaultValue: "via Azure CLI sign-in")
        case .supabase: String(localized: "destination.access.supabase", defaultValue: "via Supabase API token")
        case .vercel: String(localized: "destination.access.vercel", defaultValue: "via Vercel API token")
        }
    }
}

nonisolated extension VercelEnvironment {
    var title: String {
        switch self {
        case .production: String(localized: "destination.vercel.production", defaultValue: "Production")
        case .preview: String(localized: "destination.vercel.preview", defaultValue: "Preview")
        case .development: String(localized: "destination.vercel.development", defaultValue: "Development")
        }
    }
}

nonisolated extension DestinationModel {
    /// The row title: the vault name, the project reference, or "project · environment".
    var title: String {
        switch target {
        case .vercel(_, let projectName, _, let environment): "\(projectName) · \(environment.title)"
        default: target.displayName
        }
    }

    /// The row's second line: the provider and the stage ("Key Vault · production").
    var subtitle: String {
        [provider.shortTitle, stage].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Key Vault · kv-sample-prod" (Copy To menus, the review).
    var copyTargetTitle: String {
        "\(provider.shortTitle) · \(title)"
    }
}
