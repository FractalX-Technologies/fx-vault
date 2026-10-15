import EnvTools
import Foundation
import Observation
import VaultCore
import VaultData

/// Share › File… (§9.1–§9.3, §10 `ShareExportScreen`, D30):
/// 1. **Authenticate** with Touch ID or the master password (`ReauthGate.authorizeShare(.fileExport)`).
/// 2. **Choose the scope** in the tree (one secret, an environment or the whole repository).
/// 3. **Create**: `SharingRepository.exportFile` seals the selection under a fresh 6-word
///    passphrase into a private staging folder (0600 file, 0700 folder).
/// 4. **Passphrase**: shown once with Copy (concealed, cleared after 30 s), the "send it through
///    a different app" hint and the "I've saved it" confirmation.
/// 5. **Deliver**: Save (NSSavePanel, written again 0600 with `SecureFileWriter`) or Share
///    (NSSharingServicePicker: AirDrop, Mail, Messages).
///
/// The passphrase is held only while the sheet is open and dropped on close and on lock; it is
/// never logged. The staged file is ciphertext and is removed when the sheet closes.
@Observable
final class ShareExportViewModel: LockObserving {
    enum Step: Equatable {
        case authenticate
        case chooseScope
        case creating
        case passphrase
    }

    private(set) var step: Step = .authenticate
    let reauth: ShareReauthModel
    private(set) var tree: ShareScopeTreeModel?
    /// Names and counts of the checked scope (never values).
    private(set) var preview: ShareExportPreviewModel?
    private(set) var isLoadingTree = false
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
    @ObservationIgnored private let context: ShareExportContext
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let identity: ShareLocalIdentityModel
    @ObservationIgnored private let loader: ShareScopeTreeLoader
    @ObservationIgnored private let stagingRoot: URL?
    @ObservationIgnored private var staging: ShareStagingFolder?
    /// The encrypted file waiting to be saved or sent.
    @ObservationIgnored private(set) var stagedFileURL: URL?
    @ObservationIgnored private var isShareInFlight = false
    @ObservationIgnored private var isClosed = false

    init(
        context: ShareExportContext,
        dependencies: FeatureDependencies,
        delivery: any ShareFileDelivering = SystemShareFileDelivery(),
        identity: ShareLocalIdentityModel = .current,
        stagingRoot: URL? = nil
    ) {
        self.context = context
        self.dependencies = dependencies
        self.delivery = delivery
        self.identity = identity
        self.stagingRoot = stagingRoot
        loader = ShareScopeTreeLoader(config: dependencies.config, sharing: dependencies.sharing)
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

    /// Loads the tree and tries Touch ID once (no error when Touch ID is off).
    func start() async {
        await loadTree()
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

    // MARK: - Step 2: scope

    func setChecked(_ checked: Bool, for node: ShareScopeNodeModel) {
        let previous = selection
        tree?.setChecked(checked, for: node)
        guard selection != previous else { return }
        // The summary must always describe the checked scope: Create waits for the new one.
        preview = nil
        Task { await refreshPreview() }
    }

    var selection: ShareSelectionModel? {
        tree?.selection
    }

    var canCreate: Bool {
        step == .chooseScope && selection != nil && preview != nil
    }

    // MARK: - Step 3: create

    /// Seals the checked scope into the staged file and shows the passphrase. Consumes the
    /// authorization: a failure after that needs a new authentication.
    func createShareFile() async {
        guard canCreate, let selection else { return }
        guard let authorization = reauth.takeAuthorization() else {
            step = .authenticate
            return
        }
        step = .creating
        do {
            let folder = try staging ?? ShareStagingFolder(root: stagingRoot ?? ShareStagingFolder.defaultRoot)
            staging = folder
            let destination = folder.fileURL(named: fileName)
            let result = try await dependencies.sharing.exportFile(
                selection,
                to: destination,
                senderName: identity.displayName,
                appVersion: identity.appVersion,
                authorization: authorization,
                existingFile: .replace
            )
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

    private func loadTree() async {
        isLoadingTree = true
        defer { isLoadingTree = false }
        do {
            let repositoryID = try await loader.repositoryID(for: context.selection)
            tree = try await loader.tree(repositoryID: repositoryID, selection: context.selection)
            await refreshPreview()
        } catch {
            alert = error.presentation
        }
    }

    private func refreshPreview() async {
        guard let selection else {
            preview = nil
            return
        }
        do {
            let fresh = try await dependencies.sharing.previewExport(selection)
            if selection == self.selection {
                preview = fresh
            }
        } catch {
            preview = nil
            alert = error.presentation
        }
    }
}
