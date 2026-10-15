import GitHubKit
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

/// An error type a feature maps to text itself (UI feature contract): conform it in the
/// feature's folder (`[Type]+Extension.swift`) and ``Swift/Error/presentation`` uses it. VaultData
/// errors without a mapping here (`EnvFileError`, `SharingError`) get the generic message until
/// their feature conforms them.
protocol PresentableError: Error {
    nonisolated var errorPresentation: ErrorPresentationModel { get }
}

nonisolated extension Error {
    /// The localized presentation of any error the vault layers throw. Package errors carry no
    /// text (D24); unknown errors get a generic message and are never shown raw, because a raw
    /// description could include a path or a name.
    var presentation: ErrorPresentationModel {
        switch self {
        case let error as any PresentableError:
            error.errorPresentation
        case let error as GHError:
            error.presentation
        case let error as GitError:
            error.presentation
        case let error as GitHubEnvironmentError:
            error.presentation
        case let error as RepoCatalogError:
            error.presentation
        case let error as ConfigRepositoryError:
            error.presentation
        case let error as RepoCreationError:
            error.presentation
        case let error as SyncRepositoryError:
            error.presentation
        case let error as DriftRepositoryError:
            error.presentation
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
