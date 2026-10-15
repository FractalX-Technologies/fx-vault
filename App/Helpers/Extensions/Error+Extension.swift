import VaultCore
import VaultData

/// A localized title and message for an error shown inline or in an alert.
nonisolated struct ErrorPresentationModel: Equatable, Identifiable {
    let title: String
    let message: String

    var id: String {
        title + message
    }
}

nonisolated extension Error {
    /// The localized presentation of any error the vault layers throw. Package errors carry no
    /// text (D24); unknown errors get a generic message and are never shown raw, because a raw
    /// description could include a path or a name.
    var presentation: ErrorPresentationModel {
        switch self {
        case let error as VaultError:
            ErrorPresentationModel(title: error.localizedTitle, message: error.localizedMessage)
        case let error as ValidationError:
            ErrorPresentationModel(
                title: String(localized: "error.validation.title", defaultValue: "Check this field"),
                message: error.localizedMessage
            )
        case let error as PasswordPolicyError:
            ErrorPresentationModel(
                title: String(localized: "error.password.tooWeak.title", defaultValue: "Password too weak"),
                message: error.localizedMessage
            )
        default:
            ErrorPresentationModel(
                title: String(localized: "error.generic.title", defaultValue: "Something went wrong"),
                message: String(
                    localized: "error.generic.message",
                    defaultValue: "Try again. If it keeps happening, quit and reopen FX Vault."
                )
            )
        }
    }

    /// True for a user cancel, or the Touch ID prompt's password fallback (no message is shown;
    /// screens that can take the password offer it instead).
    var isCancellation: Bool {
        if self is CancellationError { return true }
        guard let error = self as? VaultError else { return false }
        return error == .cancelled || error == .passwordFallbackRequested
    }
}
