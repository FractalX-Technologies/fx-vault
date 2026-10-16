import Foundation
import SharingKit
import VaultCore
import VaultData

/// Chat wording for every abort (the share texts talk about a share).
nonisolated extension NearbyAbortModel {
    var chatMessage: String {
        switch reason {
        case .sasRejected:
            String(localized: "chat.abort.sasRejected", defaultValue: "The codes didn't match, so the chat was stopped.")
        case .peerAborted(.sasRejected):
            String(
                localized: "chat.abort.peerSasRejected",
                defaultValue: "The other person pressed Don't Match, so the chat was stopped."
            )
        case .cancelled, .peerAborted(.cancelled):
            String(localized: "chat.abort.cancelled", defaultValue: "The chat was cancelled.")
        case .timeout(.handshake), .peerAborted(.timeout):
            String(localized: "chat.abort.timeout.handshake", defaultValue: "The other Mac didn't answer in time.")
        case .timeout(.sas):
            String(localized: "chat.abort.timeout.sas", defaultValue: "The codes were not confirmed in time.")
        case .timeout(.chatIdle):
            String(
                localized: "chat.abort.timeout.idle",
                defaultValue: "The chat ended after \(Self.idleMinutes) minutes without messages."
            )
        case .timeout(.keepalive):
            String(localized: "chat.abort.timeout.keepalive", defaultValue: "The other Mac stopped answering.")
        case .timeout:
            String(localized: "chat.abort.timeout", defaultValue: "The chat took too long and was stopped.")
        case .disconnected:
            String(localized: "chat.abort.disconnected", defaultValue: "The other Mac disconnected.")
        case .secondPeer:
            String(
                localized: "chat.abort.secondPeer",
                defaultValue: "Another Mac tried to join this chat, so it was stopped."
            )
        case .unsupportedVersion, .unsupportedSuite, .suiteMismatch, .peerAborted(.unsupportedVersion),
             .peerAborted(.unsupportedSuite):
            String(
                localized: "chat.abort.version",
                defaultValue: "The other Mac runs an FX Vault version that can't chat with this one. Update both Macs."
            )
        case .payloadTooLarge:
            String(localized: "chat.abort.tooLarge", defaultValue: "An attachment was too large to send.")
        case .teammateNotRecognized:
            String(
                localized: "chat.abort.teammateNotRecognized",
                defaultValue: "The other Mac is not the teammate you chose, so the chat was stopped."
            )
        case .signatureInvalid:
            String(
                localized: "chat.abort.signatureInvalid",
                defaultValue: "The other Mac couldn't prove it is your teammate, so the chat was stopped."
            )
        case .unexpectedMessage, .commitmentMismatch, .invalidKey, .decryptionFailed, .sequenceMismatch,
             .sequenceExhausted, .oversizeFrame, .malformedFrame, .payloadMismatch, .unknownItemIDs, .invalidPackage,
             .peerAborted:
            String(
                localized: "chat.abort.security",
                defaultValue: "The connection could not be verified, so the chat was stopped."
            )
        }
    }

    /// The §9.4 warning, worded for a chat.
    static var chatInterceptionWarning: String {
        String(localized: "chat.abort.interception", defaultValue: "Someone nearby may be trying to intercept this chat.")
    }

    private static var idleMinutes: Int64 {
        Timeouts.chatIdle.components.seconds / Timeouts.secondsPerMinute
    }
}

/// Localized text for ``ChatError`` (D24: packages carry no text).
nonisolated extension ChatError: PresentableError {
    var errorPresentation: ErrorPresentationModel {
        switch self {
        case .sessionFinished, .actionNotAllowed:
            ErrorPresentationModel(
                title: String(localized: "chat.error.ended.title", defaultValue: "The chat isn't open"),
                message: String(
                    localized: "chat.error.ended.message",
                    defaultValue: "This conversation has ended or the codes were not confirmed yet."
                )
            )
        case .emptyMessage:
            ErrorPresentationModel(
                title: String(localized: "chat.error.empty.title", defaultValue: "Nothing to send"),
                message: String(
                    localized: "chat.error.empty.message",
                    defaultValue: "The message is empty after removing invisible characters."
                )
            )
        case .messageTooLarge:
            ErrorPresentationModel(
                title: String(localized: "chat.error.tooLong.title", defaultValue: "Message too long"),
                message: String(
                    localized: "chat.error.tooLong.message",
                    defaultValue: "Shorten the message, or send it in parts."
                )
            )
        case .unknownAttachment:
            ErrorPresentationModel(
                title: String(localized: "chat.error.attachmentGone.title", defaultValue: "Attachment no longer available"),
                message: String(
                    localized: "chat.error.attachmentGone.message",
                    defaultValue: "The other Mac withdrew it, or it was already saved or dismissed."
                )
            )
        case .invalidAttachment:
            ErrorPresentationModel(
                title: String(localized: "chat.error.attachmentInvalid.title", defaultValue: "This item can't be attached"),
                message: String(
                    localized: "chat.error.attachmentInvalid.message",
                    defaultValue: "Attach one secret or variable that has a value, or a whole repository."
                )
            )
        case .attachmentTooLarge:
            ErrorPresentationModel(
                title: String(localized: "chat.error.attachmentTooLarge.title", defaultValue: "Too large for the chat"),
                message: String(
                    localized: "chat.error.attachmentTooLarge.message",
                    defaultValue: "Share it with Share › File… or Share › Nearby… instead."
                )
            )
        case .peerNeedsUpdate:
            ErrorPresentationModel(
                title: String(localized: "chat.error.peerNeedsUpdate.title", defaultValue: "Your teammate needs FX Vault 0.4"),
                message: String(
                    localized: "chat.error.peerNeedsUpdate.message",
                    defaultValue: "Their FX Vault cannot receive a whole repository. Ask them to update, then start a new chat, or share the repository as a file."
                )
            )
        case .tooManyAttachments:
            ErrorPresentationModel(
                title: String(localized: "chat.error.tooMany.title", defaultValue: "Too many open attachments"),
                message: String(
                    localized: "chat.error.tooMany.message",
                    defaultValue: "Wait until the other person saves or dismisses one, then attach again."
                )
            )
        }
    }
}

/// Localized text for ``NearbyChatError``.
nonisolated extension NearbyChatError: PresentableError {
    var errorPresentation: ErrorPresentationModel {
        switch self {
        case .chat(let error):
            error.errorPresentation
        case .sharing(let error):
            error.errorPresentation
        case .valueMissing:
            ErrorPresentationModel(
                title: String(localized: "chat.error.valueMissing.title", defaultValue: "This secret has no value"),
                message: String(
                    localized: "chat.error.valueMissing.message",
                    defaultValue: "Its value is not in your vault. Fill it in first, then attach it."
                )
            )
        case .attachmentUnavailable:
            ErrorPresentationModel(
                title: String(localized: "chat.error.valueGone.title", defaultValue: "The value is no longer here"),
                message: String(
                    localized: "chat.error.valueGone.message",
                    defaultValue: "It was wiped when the preview closed or the chat ended. Ask your teammate to attach it again."
                )
            )
        }
    }
}
