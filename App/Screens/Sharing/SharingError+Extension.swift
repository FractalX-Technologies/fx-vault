import SharingKit
import VaultCore
import VaultData

/// Localized text for every ``SharingError`` (D24: packages carry no text).
///
/// Every `.fxvault` read failure and every invalid package shows the same "Wrong passphrase or
/// damaged file" message (§9.1), so nothing tells an attacker which check failed.
nonisolated extension SharingError: PresentableError {
    var errorPresentation: ErrorPresentationModel {
        switch self {
        case .share(let error):
            Self.presentation(of: error)
        case .authorizationInvalid:
            ErrorPresentationModel(
                title: String(localized: "share.error.authorization.title", defaultValue: "Confirm it's you again"),
                message: String(
                    localized: "share.error.authorization.message",
                    defaultValue: "The confirmation expired or was already used. Authenticate again to continue."
                )
            )
        case .repositoryNotFound, .environmentNotFound, .itemNotFound:
            ErrorPresentationModel(
                title: String(localized: "share.error.notFound.title", defaultValue: "No longer in the vault"),
                message: String(
                    localized: "share.error.notFound.message",
                    defaultValue: "What you selected was removed from the vault. Close this sheet and choose again."
                )
            )
        case .nothingToShare:
            ErrorPresentationModel(
                title: String(localized: "share.error.nothing.title", defaultValue: "Nothing to share"),
                message: String(
                    localized: "share.error.nothing.message",
                    defaultValue: "The selection has no secrets, variables or environments that can be shared."
                )
            )
        case .importBlocked(let reason):
            ErrorPresentationModel(
                title: String(localized: "share.error.blocked.title", defaultValue: "This share can't be imported"),
                message: reason.localizedMessage
            )
        case .replayNotConfirmed:
            ErrorPresentationModel(
                title: String(localized: "share.error.replay.title", defaultValue: "Confirm the warning"),
                message: String(
                    localized: "share.error.replay.message",
                    defaultValue: "This share was imported before or is old. Confirm the warning to import it anyway."
                )
            )
        case .planOutdated:
            ErrorPresentationModel(
                title: String(localized: "share.error.outdated.title", defaultValue: "The vault changed"),
                message: String(
                    localized: "share.error.outdated.message",
                    defaultValue: "Something changed since the preview. Review the preview again before importing."
                )
            )
        case .draftClosed:
            ErrorPresentationModel(
                title: String(localized: "share.error.closed.title", defaultValue: "Import already finished"),
                message: String(
                    localized: "share.error.closed.message",
                    defaultValue: "This share was already imported or discarded. Open the file again to start over."
                )
            )
        case .fileUnreadable:
            ErrorPresentationModel(
                title: String(localized: "share.error.unreadable.title", defaultValue: "Can't read the file"),
                message: String(
                    localized: "share.error.unreadable.message",
                    defaultValue: "FX Vault could not read this file. Check that it still exists and that you can open it."
                )
            )
        case .write:
            ErrorPresentationModel(
                title: String(localized: "share.error.write.title", defaultValue: "Couldn't save the file"),
                message: String(
                    localized: "share.error.write.message",
                    defaultValue: "FX Vault could not write the share file there. Choose another folder."
                )
            )
        case .productionNotShared:
            ErrorPresentationModel(
                title: String(localized: "share.error.production.title", defaultValue: "Production is never shared"),
                message: String(
                    localized: "share.error.production.message",
                    defaultValue: "The selection includes a production stage. Uncheck production to share the rest."
                )
            )
        case .config(let error):
            (error as any Error).presentation
        case .validation(let error):
            (error as any Error).presentation
        case .vault(let error):
            (error as any Error).presentation
        case .store, .unexpected:
            ErrorPresentationModel(
                title: String(localized: "share.error.generic.title", defaultValue: "Sharing failed"),
                message: String(
                    localized: "share.error.generic.message",
                    defaultValue: "Try again. If it keeps happening, quit and reopen FX Vault."
                )
            )
        }
    }

    /// The single message for a wrong passphrase, a damaged file and an invalid package (§9.1).
    static var wrongPassphraseOrDamagedFile: ErrorPresentationModel {
        ErrorPresentationModel(
            title: String(localized: "share.error.invalidFile.title", defaultValue: "Wrong passphrase or damaged file"),
            message: String(
                localized: "share.error.invalidFile.message",
                defaultValue: "Check the six words with the sender. If they are right, ask for a new share file."
            )
        )
    }

    /// True for the failures that must show ``wrongPassphraseOrDamagedFile``.
    var isWrongPassphraseOrDamagedFile: Bool {
        switch self {
        case .share(.invalidFile), .share(.invalidPackage): true
        default: false
        }
    }

    private static func presentation(of error: ShareError) -> ErrorPresentationModel {
        switch error {
        case .invalidFile, .invalidPackage:
            wrongPassphraseOrDamagedFile
        case .invalidPassphrase(let issue):
            ErrorPresentationModel(
                title: String(localized: "share.error.passphrase.title", defaultValue: "Check the passphrase"),
                message: issue.localizedMessage
            )
        case .wordlistUnavailable:
            ErrorPresentationModel(
                title: String(localized: "share.error.wordlist.title", defaultValue: "Passphrases unavailable"),
                message: String(
                    localized: "share.error.wordlist.message",
                    defaultValue: "The passphrase word list failed its integrity check. Reinstall FX Vault."
                )
            )
        case .payloadTooLarge:
            ErrorPresentationModel(
                title: String(localized: "share.error.tooLarge.title", defaultValue: "Too large to share"),
                message: String(
                    localized: "share.error.tooLarge.message",
                    defaultValue: "Share one environment or fewer items at a time."
                )
            )
        case .encryptionFailed:
            ErrorPresentationModel(
                title: String(localized: "share.error.encryption.title", defaultValue: "Couldn't encrypt the share"),
                message: String(
                    localized: "share.error.encryption.message",
                    defaultValue: "Nothing was written. Try again."
                )
            )
        case .cancelled:
            ErrorPresentationModel(
                title: String(localized: "share.error.cancelled.title", defaultValue: "Cancelled"),
                message: String(localized: "share.error.cancelled.message", defaultValue: "Nothing was shared.")
            )
        case .importActionNotAllowed:
            ErrorPresentationModel(
                title: String(localized: "share.error.action.title", defaultValue: "Not available"),
                message: String(
                    localized: "share.error.action.message",
                    defaultValue: "That choice isn't available for this item."
                )
            )
        case .expired:
            ErrorPresentationModel(
                title: String(localized: "share.error.expired.title", defaultValue: "This share file has expired"),
                message: String(
                    localized: "share.error.expired.message",
                    defaultValue: "Ask the sender for a new one."
                )
            )
        }
    }
}
