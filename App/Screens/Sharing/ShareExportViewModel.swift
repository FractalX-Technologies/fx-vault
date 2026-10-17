import EnvTools
import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// "Save as File…" for a configuration received in Nearby Chat (v0.4.0, §10 `ShareExportScreen`):
/// 1. **Authenticate** with Touch ID or the master password (`ReauthGate.authorizeShare(.fileExport)`).
/// 2. **Review** what was received (names and counts).
/// 3. **Create**: `NearbyChatConversation.saveAttachment` seals the received package under a
///    fresh 6-word passphrase into a private staging folder (0600 file, 0700 folder). Since
///    v0.9.0 it is a schema 4 bundle in format 2 that expires after 7 days; a package with a
///    production environment is refused (production never travels under a passphrase).
/// 4. **Passphrase**: shown once with Copy (concealed, cleared after 30 s), the "send it through
///    a different app" hint and the "I've saved it" confirmation.
/// 5. **Deliver**: Save (NSSavePanel, written again 0600 with `SecureFileWriter`) or Share
///    (NSSharingServicePicker: AirDrop, Mail, Messages).
///
/// The passphrase is held only while the sheet is open and dropped on close and on lock; it is
/// never logged. The staged file is ciphertext and is removed when the sheet closes.
///
/// Sharing from the vault is ``ProjectShareViewModel`` (v0.9.0).
@Observable
final class ShareExportViewModel: LockObserving {
    /// A configuration received in Nearby Chat, kept by its conversation until it is imported or
    /// the chat ends.
    struct ChatAttachmentSource {
        let conversation: NearbyChatConversation
        let attachmentID: ChatAttachmentID
    }

    enum Step: Equatable {
        case authenticate
        case chooseScope
        case creating
        case passphrase
    }

    private(set) var step: Step = .authenticate
    let reauth: ShareReauthModel
    /// Names and counts of what was received (never values).
    private(set) var preview: ShareExportPreviewModel?
    /// The passphrase, shown once (`w1-…-w6`).
    private(set) var passphrase: String?
    /// "I've saved it": unlocks Save and Share.
    var hasSavedPassphrase = false
    private(set) var savedFileURL: URL?
    private(set) var hasSent = false
    private(set) var isDelivering = false
    /// A short confirmation ("Passphrase copied…").
    private(set) var notice: String?
    var alert: ErrorPresentationModel?
    /// `FX Vault Share 2026-10-14.fxvault`.
    let fileName: String

    @ObservationIgnored let delivery: any ShareFileDelivering
    @ObservationIgnored private let source: ChatAttachmentSource
    @ObservationIgnored private let dependencies: FeatureDependencies
    /// Called once when the sheet closes, with whether the file was saved or sent (chat source).
    @ObservationIgnored private var onFinish: ((_ wroteFile: Bool) -> Void)?
    @ObservationIgnored private let stagingRoot: URL?
    @ObservationIgnored private var staging: ShareStagingFolder?
    /// The encrypted file waiting to be saved or sent.
    @ObservationIgnored private(set) var stagedFileURL: URL?
    @ObservationIgnored private var isShareInFlight = false
    @ObservationIgnored private var isClosed = false

    /// "Save as File…" for a configuration received in Nearby Chat (v0.4.0).
    ///
    /// - Parameter onFinish: called once on close, with whether the file was saved or sent.
    init(
        chatAttachment: ChatAttachmentSource,
        dependencies: FeatureDependencies,
        delivery: any ShareFileDelivering = SystemShareFileDelivery(),
        stagingRoot: URL? = nil,
        onFinish: @escaping (_ wroteFile: Bool) -> Void
    ) {
        source = chatAttachment
        self.dependencies = dependencies
        self.delivery = delivery
        self.stagingRoot = stagingRoot
        self.onFinish = onFinish
        reauth = ShareReauthModel(
            purpose: .fileExport,
            reauth: dependencies.reauth,
            session: dependencies.session,
            touchIDStatus: dependencies.touchIDStatus()
        )
        fileName = Self.fileName(for: dependencies.clock.now)
        dependencies.actions.addLockObserver(self)
    }

    /// The default file name (§9.1): `FX Vault Share <yyyy-MM-dd>.fxvault`, local date.
    static func fileName(for date: Date) -> String {
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let base = String(localized: "share.export.fileName", defaultValue: "FX Vault Share \(day)")
        return base + "." + fileExtension
    }

    static let fileExtension = "fxvault"

    // MARK: - Step 1: authenticate

    /// Loads the summary of what was received and tries Touch ID once (no error when Touch ID is
    /// off).
    func start() async {
        await loadPreview()
        await authenticateWithTouchID(automatic: true)
    }

    func authenticateWithTouchID(automatic: Bool = false) async {
        guard step == .authenticate else { return }
        if await reauth.authorizeWithTouchID(automatic: automatic) {
            step = .chooseScope
        }
    }

    func authenticateWithPassword() async {
        guard step == .authenticate else { return }
        if await reauth.authorizeWithPassword() {
            step = .chooseScope
        }
    }

    // MARK: - Step 2: review

    var canCreate: Bool {
        step == .chooseScope && preview != nil
    }

    // MARK: - Step 3: create

    /// Seals the received package into the staged file and shows the passphrase. Consumes the
    /// authorization: a failure after that needs a new authentication.
    func createShareFile() async {
        guard canCreate else { return }
        guard let authorization = reauth.takeAuthorization() else {
            step = .authenticate
            return
        }
        step = .creating
        do {
            let folder = try staging ?? ShareStagingFolder(root: stagingRoot ?? ShareStagingFolder.defaultRoot)
            staging = folder
            let destination = folder.fileURL(named: fileName)
            let result = try await source.conversation.saveAttachment(source.attachmentID, to: destination, authorization: authorization)
            defer { result.passphrase.wipe() }
            guard let words = result.passphrase.utf8String() else { throw SharingError.unexpected }
            passphrase = words
            preview = result.preview
            stagedFileURL = result.fileURL
            step = .passphrase
        } catch {
            alert = error.presentation
            step = authorization.isUsable ? .chooseScope : .authenticate
            if step == .authenticate {
                reauth.reset()
            }
        }
    }

    // MARK: - Step 4: passphrase

    /// Copies the passphrase (concealed, cleared after 30 s, §5.9).
    func copyPassphrase() {
        guard let passphrase else { return }
        dependencies.clipboard.copy(passphrase)
        notice = String(
            localized: "share.export.copied",
            defaultValue: "Passphrase copied. The clipboard clears in \(dependencies.clipboard.clearDelay.wholeSeconds) seconds."
        )
    }

    // MARK: - Step 5: deliver

    var canDeliver: Bool {
        step == .passphrase && hasSavedPassphrase && !isDelivering && stagedFileURL != nil
    }

    /// Save…: asks where, then writes the encrypted file there (0600).
    func saveToFile() async {
        guard canDeliver, let stagedFileURL else { return }
        isDelivering = true
        defer { isDelivering = false }
        guard let destination = await delivery.chooseSaveDestination(suggestedName: fileName) else { return }
        do {
            let data = try Data(contentsOf: stagedFileURL, options: .uncached)
            try SecureFileWriter().write(data, to: destination, existingFile: .replace)
            savedFileURL = destination
            notice = String(
                localized: "share.export.saved",
                defaultValue: "Saved “\(destination.lastPathComponent)”. Send the passphrase separately."
            )
        } catch let error as SecureFileWriteError {
            alert = SharingError.write(error).presentation
        } catch {
            alert = SharingError.fileUnreadable.presentation
        }
    }

    /// Share…: the system sharing picker (AirDrop) with the encrypted file.
    func shareFile() {
        guard canDeliver, let stagedFileURL else { return }
        isDelivering = true
        isShareInFlight = true
        delivery.share(fileURL: stagedFileURL) { [weak self] outcome in
            self?.deliveryFinished(outcome)
        }
    }

    private func deliveryFinished(_ outcome: ShareDeliveryOutcome) {
        isDelivering = false
        isShareInFlight = false
        switch outcome {
        case .shared:
            hasSent = true
            notice = String(
                localized: "share.export.sent",
                defaultValue: "File sent. Send the passphrase through a different app."
            )
        case .cancelled:
            break
        case .failed:
            alert = ErrorPresentationModel(
                title: String(localized: "share.export.sendFailed.title", defaultValue: "Couldn't send the file"),
                message: String(
                    localized: "share.export.sendFailed.message",
                    defaultValue: "Try again, or save the file and send it another way."
                )
            )
        }
        if isClosed {
            staging?.remove()
            staging = nil
        }
    }

    // MARK: - Lifetime

    /// The sheet closed: drops the passphrase and the authorization and removes the staged file
    /// (after a running AirDrop hand-off finishes).
    func close() {
        isClosed = true
        wipe()
        if !isShareInFlight {
            staging?.remove()
            staging = nil
        }
        let finish = onFinish
        onFinish = nil
        finish?(savedFileURL != nil || hasSent)
    }

    func vaultDidLock() {
        wipe()
        step = .authenticate
    }

    private func wipe() {
        passphrase = nil
        hasSavedPassphrase = false
        notice = nil
        reauth.reset()
    }

    // MARK: - Loading

    private func loadPreview() async {
        preview = await source.conversation.receivedPreview(source.attachmentID)
        if preview == nil {
            alert = NearbyChatError.attachmentUnavailable.presentation
        }
    }
}
