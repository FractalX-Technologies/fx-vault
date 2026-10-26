import Foundation

/// Counted texts of the Connect phase (automatic grammar agreement: "1 repository").
enum ConnectCopy {
    static func personalRepositories(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "connect.source.personal",
            defaultValue: "^[\(count) personal repository](inflect: true)"
        ))
    }

    static func organizations(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "connect.summary.organizationCount",
            defaultValue: "^[\(count) organization](inflect: true)"
        ))
    }

    static func repositories(_ count: Int, environments: Int) -> String {
        String(inflected: AttributedString(
            localized: "connect.summary.repositoryCount",
            defaultValue: "^[\(count) repository](inflect: true) · ^[\(environments) environment](inflect: true)"
        ))
    }

    static func keyVaults(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "connect.summary.keyVaultCount",
            defaultValue: "^[\(count) vault](inflect: true)"
        ))
    }

    static func vaultsSelected(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "connect.azure.selected",
            defaultValue: "^[\(count) vault](inflect: true) selected · Secrets with values"
        ))
    }

    /// A listed vault Choose Vaults… leaves alone (1.0 S1b): "westeurope · In FX Vault".
    static func vaultSaved(location: String) -> String {
        String(localized: "connect.azure.vault.saved", defaultValue: "\(location) · In FX Vault")
    }

    static func total(secrets: Int, variables: Int) -> String {
        String(inflected: AttributedString(
            localized: "connect.summary.total",
            defaultValue: "Total · ^[\(secrets) secret](inflect: true) · ^[\(variables) variable](inflect: true)"
        ))
    }
}
