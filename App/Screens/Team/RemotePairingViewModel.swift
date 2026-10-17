import AppKit
import Foundation
import Observation
import SharingKit
import UniformTypeIdentifiers
import VaultCore
import VaultData

/// What ``RemotePairingViewModel`` needs from VaultData's `TeamRepository` (v0.9.0). The live
/// implementation is the repository itself; view-model tests use a fake.
protocol RemotePairingServicing {
    func pairingFileKind(of file: Data) throws(TeamRepositoryError) -> RemotePairingFileKind
    func makeInvitation(as identity: SpaceLocalIdentityModel) throws(TeamRepositoryError) -> Data
    func readInvitation(_ file: Data) throws(TeamRepositoryError) -> RemoteInvitationReadModel
    func makeReply(to invitation: RemoteInvitationModel, as identity: SpaceLocalIdentityModel) throws(TeamRepositoryError) -> RemotePairingReplyFileModel
    func confirmInviter(_ inviter: TeamPublicCardModel) throws(TeamRepositoryError) -> RemotePairingOutcome
    func readReply(_ file: Data) throws(TeamRepositoryError) -> RemoteReplyReadModel
    func confirmReplier(_ teammate: TeamCardModel) throws(TeamRepositoryError) -> RemotePairingOutcome
}

extension TeamRepository: RemotePairingServicing {
    func pairingFileKind(of file: Data) throws(TeamRepositoryError) -> RemotePairingFileKind {
        try Self.pairingFileKind(of: file)
    }
}

/// Add Teammate › Not Nearby… (v0.9.0, P4), on either Mac:
///
/// - **Inviter (A):** ``createInvitation()`` writes an invitation card to send; opening the reply
///   (``open(_:)``) shows the six words; ``confirm()`` stores the replier.
/// - **Invited (B):** opening the invitation shows who sent it; ``createReply()`` writes the reply
///   and shows the six words; ``confirm()`` stores the inviter.
///
/// Only ``confirm()`` writes a teammate: reading and making files store nothing, and Cancel (or
/// closing the sheet) leaves the vault as it was. Card files hold public keys only; they are
/// staged in a private temporary folder that is removed when the sheet closes.
@Observable
final class RemotePairingViewModel: Identifiable {
    enum Step: Equatable {
        /// A: what Not Nearby does, and Create Invitation.
        case start
        /// A: the invitation is ready to send.
        case invitationReady
        /// B: an opened invitation.
        case invitation(RemotePairingPersonModel)
        /// B: the reply is ready to send; compare the code.
        case replyReady(RemotePairingPersonModel, code: [String])
        /// A: an opened reply; compare the code.
        case reply(RemotePairingPersonModel, code: [String])
        /// Stored (or, for a device that was already a teammate, updated).
        case paired(name: String, wasUpdate: Bool)
        case failed(String)
    }

    let id = UUID()
    private(set) var step: Step
    /// A short confirmation after sharing or saving a card file.
    private(set) var notice: String?
    /// The staged card file of the current step (invitation or reply).
    private(set) var stagedFile: URL?

    @ObservationIgnored let delivery: any PairingCardDelivering
    @ObservationIgnored private let service: any RemotePairingServicing
    @ObservationIgnored private let identity: () -> SpaceLocalIdentityModel
    @ObservationIgnored private let makeStagingFolder: () throws -> ShareStagingFolder
    @ObservationIgnored private var staging: ShareStagingFolder?
    @ObservationIgnored private var invitation: RemoteInvitationModel?
    @ObservationIgnored private var inviter: TeamPublicCardModel?
    @ObservationIgnored private var replier: TeamCardModel?

    /// - Parameters:
    ///   - file: an opened `.fxvcard` (an invitation or a reply); nil starts at Create Invitation.
    ///   - makeStagingFolder: where card files are written before they are shared or saved.
    init(
        service: any RemotePairingServicing,
        identity: @escaping () -> SpaceLocalIdentityModel,
        delivery: any PairingCardDelivering = SystemPairingCardDelivery(),
        file: Data? = nil,
        makeStagingFolder: @escaping () throws -> ShareStagingFolder = { try ShareStagingFolder() }
    ) {
        self.service = service
        self.identity = identity
        self.delivery = delivery
        self.makeStagingFolder = makeStagingFolder
        step = .start
        if let file {
            open(file)
        }
    }

    /// Reads an opened card file and routes it by kind.
    static func readFile(at url: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              size <= Limits.maxPairingCardFileBytes
        else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Steps

    /// An opened `.fxvcard`: an invitation (this Mac is B) or a reply (this Mac is A).
    func open(_ file: Data) {
        do {
            switch try service.pairingFileKind(of: file) {
            case .invitation:
                let read = try service.readInvitation(file)
                invitation = read.invitation
                inviter = read.inviter
                step = .invitation(RemotePairingPersonModel(card: read.inviter, existing: read.existingTeammate))
            case .reply:
                let read = try service.readReply(file)
                replier = read.teammate
                step = .reply(RemotePairingPersonModel(card: read.teammate, existing: read.existingTeammate), code: read.code.words)
            }
        } catch {
            step = .failed(error.presentation.message)
        }
    }

    /// Shows `message` instead of a step (an opened file that could not be read).
    func fail(_ message: String) {
        step = .failed(message)
    }

    /// Step 1 (A): writes the invitation to send.
    func createInvitation() {
        guard step == .start else { return }
        do {
            let file = try service.makeInvitation(as: identity())
            try stage(file, named: RemotePairingCopy.invitationFileName)
            step = .invitationReady
        } catch {
            step = .failed(error.presentation.message)
        }
    }

    /// Step 2 (B): writes the reply to send back and shows the code.
    func createReply() {
        guard case .invitation(let person) = step, let invitation else { return }
        do {
            let reply = try service.makeReply(to: invitation, as: identity())
            try stage(reply.file, named: RemotePairingCopy.replyFileName)
            step = .replyReady(person, code: reply.code.words)
        } catch {
            step = .failed(error.presentation.message)
        }
    }

    /// Step 4, after the people compared the words: stores the other device. The only write.
    func confirm() {
        do {
            switch step {
            case .replyReady(let person, _):
                guard let inviter else { return }
                let outcome = try service.confirmInviter(inviter)
                step = .paired(name: person.name, wasUpdate: outcome == .updated)
            case .reply(let person, _):
                guard let replier else { return }
                let outcome = try service.confirmReplier(replier)
                step = .paired(name: person.name, wasUpdate: outcome == .updated)
            default:
                return
            }
        } catch {
            step = .failed(error.presentation.message)
        }
    }

    // MARK: - Delivery

    /// Offers the staged card to the sharing services (WhatsApp, Mail, Messages, AirDrop).
    func share() {
        guard let stagedFile else { return }
        delivery.share(fileURL: stagedFile) { [weak self] outcome in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if outcome == .shared {
                    notice = RemotePairingCopy.shared
                }
            }
        }
    }

    /// Saves a copy of the staged card where the user chooses.
    func save() async {
        guard let stagedFile else { return }
        guard let destination = await delivery.chooseSaveDestination(suggestedName: stagedFile.lastPathComponent) else { return }
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: stagedFile, to: destination)
            notice = RemotePairingCopy.saved
        } catch {
            notice = nil
            step = .failed(RemotePairingCopy.unreadableFile)
        }
    }

    /// The sheet closed (Cancel, Done or a lock): removes the staged card. Stores nothing.
    func close() {
        staging?.remove()
        staging = nil
        stagedFile = nil
        invitation = nil
        inviter = nil
        replier = nil
    }

    var isFinished: Bool {
        if case .paired = step { true } else { false }
    }

    private func stage(_ file: Data, named name: String) throws {
        staging?.remove()
        let folder = try makeStagingFolder()
        staging = folder
        let url = folder.fileURL(named: "\(name).\(RemotePairingProtocol.fileExtension)")
        try file.write(to: url, options: .atomic)
        stagedFile = url
        notice = nil
    }
}

/// The other person in a remote pairing: names as their card states them (unverified until the
/// words are compared).
struct RemotePairingPersonModel: Hashable {
    let name: String
    /// "login · Mac name".
    let detail: String
    /// The device is already a teammate (pairing again updates its card).
    let isExistingTeammate: Bool

    init(name: String, detail: String, isExistingTeammate: Bool) {
        self.name = name
        self.detail = detail
        self.isExistingTeammate = isExistingTeammate
    }

    init(card: TeamPublicCardModel, existing: TeammateModel?) {
        self.init(
            name: card.name,
            detail: [card.login, card.macName].filter { !$0.isEmpty }.joined(separator: " · "),
            isExistingTeammate: existing != nil
        )
    }

    init(card: TeamCardModel, existing: TeammateModel?) {
        self.init(
            name: card.name,
            detail: [card.login, card.macName].filter { !$0.isEmpty }.joined(separator: " · "),
            isExistingTeammate: existing != nil
        )
    }
}

/// Where a teammate card goes: the sharing picker or a save panel (v0.9.0). A protocol so
/// view-model tests never open a panel.
protocol PairingCardDelivering: AnyObject {
    func chooseSaveDestination(suggestedName: String) async -> URL?
    func share(fileURL: URL, completion: @escaping (ShareDeliveryOutcome) -> Void)
}

/// The sharing picker of ``SystemShareFileDelivery`` and a save panel for `.fxvcard` files.
final class SystemPairingCardDelivery: PairingCardDelivering {
    /// The exported teammate card type (Info.plist `UTExportedTypeDeclarations`).
    static let cardFileType = UTType(exportedAs: RemotePairingProtocol.typeIdentifier)

    /// Anchors the sharing picker (``ShareDeliveryAnchor``).
    let picker = SystemShareFileDelivery()

    func chooseSaveDestination(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [Self.cardFileType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response = if let window = picker.anchorView?.window {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    func share(fileURL: URL, completion: @escaping (ShareDeliveryOutcome) -> Void) {
        picker.share(fileURL: fileURL, completion: completion)
    }
}
