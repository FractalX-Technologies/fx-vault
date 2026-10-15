import EnvTools

nonisolated extension CredentialReason {
    /// Why a variable looks like a credential (§5.13), for the editor's warning. Never quotes
    /// the value; a key reason names only the matched fragment of the name.
    var editorExplanation: String {
        switch self {
        case .keyContains(let fragment):
            String(localized: "itemEditor.credential.key", defaultValue: "The name contains \u{201C}\(fragment)\u{201D}.")
        case .urlWithCredentials:
            String(
                localized: "itemEditor.credential.url",
                defaultValue: "The value contains a URL with a user name and password."
            )
        case .pemBlock:
            String(localized: "itemEditor.credential.pem", defaultValue: "The value contains a PEM key or certificate.")
        case .jsonWebToken:
            String(localized: "itemEditor.credential.jwt", defaultValue: "The value looks like a JSON Web Token.")
        case .knownTokenPrefix:
            String(localized: "itemEditor.credential.token", defaultValue: "The value looks like an access token.")
        case .highEntropy:
            String(localized: "itemEditor.credential.entropy", defaultValue: "The value looks like a random key or token.")
        }
    }
}
