import GitHubKit

nonisolated extension GHUnusableAccountModel {
    /// The login as gh printed it (cleaned), or a placeholder when nothing printable is left.
    var displayTitle: String {
        displayLogin.isEmpty
            ? String(localized: "gh.unusableAccount.unnamed", defaultValue: "(an account without a readable name)")
            : displayLogin
    }

    /// Why FX Vault cannot use the account.
    var reasonText: String {
        violation.localizedMessage
    }
}
