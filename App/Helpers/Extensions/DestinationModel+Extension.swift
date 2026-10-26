import VaultCore

/// Display text and symbols of runtime destinations (v0.8.0).
nonisolated extension DestinationProvider {
    /// "Azure Key Vault".
    var title: String {
        switch self {
        case .azureKeyVault: String(localized: "destination.provider.keyVault", defaultValue: "Azure Key Vault")
        }
    }

    /// A short form for chips and copy targets ("Key Vault").
    var shortTitle: String {
        switch self {
        case .azureKeyVault: String(localized: "destination.provider.keyVault.short", defaultValue: "Key Vault")
        }
    }

    /// The SF Symbol of the RUNTIME rows.
    var symbolName: String {
        switch self {
        case .azureKeyVault: "key"
        }
    }
}

nonisolated extension DestinationModel {
    /// The row title: the vault name.
    var title: String {
        target.displayName
    }

    /// The row's second line: the provider and the stage ("Key Vault · production").
    var subtitle: String {
        [provider.shortTitle, stage].compactMap { $0 }.joined(separator: " · ")
    }

    /// The Settings sheet's subtitle: the vault, and its tenant when one is set.
    var targetDescription: String {
        switch target {
        case .azureKeyVault(let vaultName, let tenantID):
            [vaultName, tenantID].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// "Key Vault · kv-sample-prod" (Copy To menus, the review).
    var copyTargetTitle: String {
        "\(provider.shortTitle) · \(title)"
    }
}
