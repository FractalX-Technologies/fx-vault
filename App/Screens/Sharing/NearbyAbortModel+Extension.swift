import SharingKit

nonisolated extension NearbyAbortModel {
    /// What happened, in words the user can act on (§9.4 abort conditions). Nothing was
    /// transferred unless the payload had already arrived and was applied.
    var localizedMessage: String {
        switch reason {
        case .sasRejected:
            String(
                localized: "nearby.abort.sasRejected",
                defaultValue: "The codes didn't match, so the share was stopped. Nothing was shared."
            )
        case .peerAborted(.sasRejected):
            String(
                localized: "nearby.abort.peerSasRejected",
                defaultValue: "Your teammate pressed Don't Match, so the share was stopped. Nothing was shared."
            )
        case .cancelled, .peerAborted(.cancelled):
            String(localized: "nearby.abort.cancelled", defaultValue: "The share was cancelled. Nothing was shared.")
        case .timeout(.handshake), .peerAborted(.timeout):
            String(
                localized: "nearby.abort.timeout.handshake",
                defaultValue: "The other Mac didn't answer in time. Nothing was shared."
            )
        case .timeout(.sas):
            String(
                localized: "nearby.abort.timeout.sas",
                defaultValue: "The codes were not confirmed in time. Nothing was shared."
            )
        case .timeout:
            String(localized: "nearby.abort.timeout", defaultValue: "The share took too long and was stopped.")
        case .disconnected:
            String(localized: "nearby.abort.disconnected", defaultValue: "The other Mac disconnected.")
        case .secondPeer:
            String(
                localized: "nearby.abort.secondPeer",
                defaultValue: "Another Mac tried to join this share, so it was stopped. Nothing was shared."
            )
        case .unsupportedVersion, .unsupportedSuite, .suiteMismatch, .peerAborted(.unsupportedVersion),
             .peerAborted(.unsupportedSuite):
            String(
                localized: "nearby.abort.version",
                defaultValue: "The other Mac runs an FX Vault version that can't share with this one. Update both Macs."
            )
        case .payloadTooLarge:
            String(localized: "nearby.abort.tooLarge", defaultValue: "The share is too large to send nearby.")
        case .unexpectedMessage, .commitmentMismatch, .invalidKey, .decryptionFailed, .sequenceMismatch,
             .sequenceExhausted, .oversizeFrame, .malformedFrame, .payloadMismatch, .unknownItemIDs, .invalidPackage,
             .peerAborted:
            String(
                localized: "nearby.abort.security",
                defaultValue: "The connection could not be verified, so the share was stopped. Nothing was imported."
            )
        }
    }

    /// The §9.4 warning shown after an abort that follows REVEAL, or two failed handshakes in a row.
    static var interceptionWarning: String {
        String(
            localized: "nearby.abort.interception",
            defaultValue: "Someone nearby may be trying to intercept this share."
        )
    }
}
