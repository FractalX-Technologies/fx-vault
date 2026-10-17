import Foundation

/// Text of Add Teammate › Not Nearby… (v0.9.0, P4): card files sent by WhatsApp, Mail or AirDrop
/// and six words compared on a call.
enum RemotePairingCopy {
    static var notNearby: String {
        String(localized: "teammates.remote.notNearby", defaultValue: "Not Nearby…")
    }

    static var notNearbyHelp: String {
        String(
            localized: "teammates.remote.notNearby.help",
            defaultValue: "Pair with someone on another network: exchange card files, then compare six words on a call."
        )
    }

    static var experimental: String {
        String(localized: "teammates.remote.experimental", defaultValue: "Experimental")
    }

    static var experimentalHelp: String {
        String(
            localized: "teammates.remote.experimental.help",
            defaultValue: "Pairing by file is new. If it fails, pair side by side with Add Teammate instead."
        )
    }

    static var eyebrow: String {
        String(localized: "teammates.add.eyebrow", defaultValue: "Teammates")
    }

    static var title: String {
        String(localized: "teammates.remote.title", defaultValue: "Pair Without Being Nearby")
    }

    // MARK: Step 1 (inviter)

    static var startSubtitle: String {
        String(
            localized: "teammates.remote.start.subtitle",
            defaultValue: "Send an invitation by WhatsApp, Mail or AirDrop. The other person answers with a reply file, then you compare six words on a call."
        )
    }

    static var steps: [String] {
        [
            String(localized: "teammates.remote.step1", defaultValue: "Send your invitation."),
            String(localized: "teammates.remote.step2", defaultValue: "They open it in FX Vault and send back a reply."),
            String(localized: "teammates.remote.step3", defaultValue: "Open their reply here."),
            String(localized: "teammates.remote.step4", defaultValue: "Call them, compare the six words, and both confirm."),
        ]
    }

    static var publicKeysNote: String {
        String(
            localized: "teammates.remote.publicKeys",
            defaultValue: "The files carry only public keys and names, never a secret. Comparing the words on a call is what proves nobody swapped a card on the way."
        )
    }

    static var createInvitation: String {
        String(localized: "teammates.remote.createInvitation", defaultValue: "Create Invitation")
    }

    static var invitationReadyTitle: String {
        String(localized: "teammates.remote.invitationReady.title", defaultValue: "Send Your Invitation")
    }

    static var invitationReadyMessage: String {
        String(
            localized: "teammates.remote.invitationReady.message",
            defaultValue: "Send this file to the person you want to pair with. It expires after 7 days. When their reply arrives, open it in FX Vault."
        )
    }

    static var invitationFileName: String {
        String(localized: "teammates.remote.invitation.fileName", defaultValue: "FX Vault teammate invitation")
    }

    static var replyFileName: String {
        String(localized: "teammates.remote.reply.fileName", defaultValue: "FX Vault teammate reply")
    }

    static var share: String {
        String(localized: "teammates.remote.share", defaultValue: "Share…")
    }

    static var save: String {
        String(localized: "teammates.remote.save", defaultValue: "Save…")
    }

    static var shared: String {
        String(localized: "teammates.remote.shared", defaultValue: "Sent. Keep this window open, or open their reply later from Finder.")
    }

    static var saved: String {
        String(localized: "teammates.remote.saved", defaultValue: "Saved. Send the file to them.")
    }

    // MARK: Step 2 (invited)

    static func invitationTitle(_ name: String) -> String {
        String(localized: "teammates.remote.invitation.title", defaultValue: "Invitation from \(name)")
    }

    static func invitationMessage(_ name: String) -> String {
        String(
            localized: "teammates.remote.invitation.message",
            defaultValue: "Create a reply and send it back to \(name). Then call them and compare the six words FX Vault shows."
        )
    }

    static func alreadyTeammate(_ name: String) -> String {
        String(
            localized: "teammates.remote.alreadyTeammate",
            defaultValue: "\(name) is already your teammate. Pairing again updates their card."
        )
    }

    static var createReply: String {
        String(localized: "teammates.remote.createReply", defaultValue: "Create Reply")
    }

    static var replyReadyTitle: String {
        String(localized: "teammates.remote.replyReady.title", defaultValue: "Send Your Reply")
    }

    static func replyReadyMessage(_ name: String) -> String {
        String(
            localized: "teammates.remote.replyReady.message",
            defaultValue: "Send this reply to \(name), then call them and compare these words. Confirm only when every word matches."
        )
    }

    // MARK: Step 3 (inviter)

    static func replyTitle(_ name: String) -> String {
        String(localized: "teammates.remote.reply.title", defaultValue: "Reply from \(name)")
    }

    static func replyMessage(_ name: String) -> String {
        String(
            localized: "teammates.remote.reply.message",
            defaultValue: "Call \(name) and compare these words. Confirm only when every word matches."
        )
    }

    // MARK: Code and outcome

    static var codeTitle: String {
        String(localized: "teammates.remote.code.title", defaultValue: "Compare these words")
    }

    static var codeWarning: String {
        String(
            localized: "teammates.remote.code.warning",
            defaultValue: "If any word differs, cancel: a card may have been changed on the way. Nobody is added until you confirm."
        )
    }

    static var wordsMatch: String {
        String(localized: "teammates.remote.wordsMatch", defaultValue: "The Words Match")
    }

    static func paired(_ name: String) -> String {
        String(
            localized: "teammates.remote.paired",
            defaultValue: "\(name) is now your teammate. You can send them share files sealed for their Mac."
        )
    }

    static func updated(_ name: String) -> String {
        String(localized: "teammates.remote.updated", defaultValue: "\(name)'s teammate card was updated.")
    }

    static var unreadableFile: String {
        String(
            localized: "teammates.remote.unreadable",
            defaultValue: "FX Vault couldn't read this file. Ask for a new invitation or reply."
        )
    }

    // MARK: Teammate rows

    static var pairedRemotely: String {
        String(localized: "teammates.remote.pairedRemotely", defaultValue: "Paired remotely")
    }

    static var waitingForNearby: String {
        String(
            localized: "teammates.remote.waitingForNearby",
            defaultValue: "Seen nearby once you meet on the same network"
        )
    }
}
