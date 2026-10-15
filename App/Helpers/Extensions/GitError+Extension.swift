import GitHubKit
import VaultCore

nonisolated extension GitError {
    var presentation: ErrorPresentationModel {
        ErrorPresentationModel(
            title: String(localized: "error.git.title", defaultValue: "git or ssh failed"),
            message: localizedMessage
        )
    }

    var localizedMessage: String {
        switch self {
        case .invalidAlias:
            String(localized: "error.git.invalidAlias", defaultValue: "This SSH alias is not valid.")
        case .invalidPath(let error):
            error.localizedMessage
        case .destinationOutsideFolder:
            String(localized: "error.git.outsideFolder", defaultValue: "The clone destination is outside the chosen folder.")
        case .destinationExists:
            String(localized: "error.git.destinationExists", defaultValue: "A folder with this repository's name already exists there.")
        case .folderAccessDenied:
            String(
                localized: "error.git.folderAccessDenied",
                defaultValue: "macOS denied access to the folder. Allow FX Vault in System Settings › Privacy & Security › Files and Folders."
            )
        case .authenticationFailed:
            String(
                localized: "error.git.authenticationFailed",
                defaultValue: "GitHub refused the SSH key. Test the account's SSH alias in Settings › Accounts."
            )
        case .hostKeyVerificationFailed:
            String(
                localized: "error.git.hostKey",
                defaultValue: "GitHub's host key is not known yet. Run ssh -T git@<alias> once in Terminal."
            )
        case .aliasNotGitHub(let hostName):
            String(localized: "error.git.aliasNotGitHub", defaultValue: "The SSH alias points to \(hostName), not github.com.")
        case .timeout:
            String(localized: "error.git.timeout", defaultValue: "git took too long. Check your connection and try again.")
        case .cancelled:
            String(localized: "error.git.cancelled", defaultValue: "The git operation was cancelled.")
        case .commandFailed, .malformedOutput, .launchFailed:
            String(localized: "error.git.failed", defaultValue: "git failed. Try again; if it keeps happening, check git in Terminal.")
        }
    }
}
