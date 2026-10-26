import EnvTools
import Foundation
import Observation
import VaultCore
import VaultData

/// The export sheet's steps (§10 `EnvExportScreen`, §5.13).
enum EnvExportStep: Equatable {
    /// ReauthGate: Touch ID or the master password, before anything else.
    case authenticate
    /// The plaintext warning, skipped and unverified names, then the save panel.
    case review
    /// The chosen folder syncs to iCloud (and Spotlight indexes it): confirm or choose again.
    case confirmCloudSync(EnvExportDestinationChoiceModel)
    /// Written: git checks and the `.gitignore` offer.
    case done(EnvExportOutcomeModel)
}

/// A destination chosen in the save panel, with its iCloud and git checks.
struct EnvExportDestinationChoiceModel: Equatable {
    let fileURL: URL
    let destination: EnvExportDestinationModel
    /// `.replace` only when a file existed when the panel returned (the panel asked to replace it).
    let existingFile: SecureFileWriter.ExistingFilePolicy
}

/// What an export wrote and where the file stands with git.
struct EnvExportOutcomeModel: Equatable {
    let result: EnvExportResultModel
    let destination: EnvExportDestinationModel
}

/// The `.gitignore` offer after writing into a git work tree that does not ignore the file.
enum EnvExportGitignoreState: Equatable {
    /// Nothing to offer (outside a repository, ignored, tracked, or the check failed).
    case notApplicable
    /// Offer to append `line` to the repository's `.gitignore`.
    case offered(line: String)
    /// The line was appended.
    case added(line: String)
    /// An equivalent line was already in force.
    case alreadyPresent
    /// The path cannot be written as an ignore pattern; the user adds it by hand.
    case manual
}

/// The button Return triggers on each step.
enum EnvExportDefaultAction: Equatable {
    case touchID
    case password
    case chooseLocation
    /// On the iCloud warning the safe choice is the default, not "Export Anyway".
    case chooseAnotherLocation
    case addToGitignore
    case done
}

/// `EnvExportScreen` (§5.13, §8 D4–D6, M5): ReauthGate first (Touch ID or the master password),
/// then a plaintext warning with the skipped value-missing secrets and the unverified share
/// items, the save panel, the iCloud/Spotlight warning when the folder syncs, a 0600 write by
/// `EnvFileRepository.export` and, after the write, the git checks: a tracked file gets the
/// "already committed" warning, a file git does not ignore gets the `.gitignore` offer.
///
/// The authorization is single-use and held only in memory; it is dropped on lock and when the
/// sheet closes. A failed write consumed it, so the sheet asks again. The view model never
/// decrypts: values exist only inside the repository during the write.
@Observable
final class EnvExportViewModel: LockObserving {
    /// The scope or folder (v0.7.0) being exported.
    let place: ItemPlaceModel
    private(set) var step: EnvExportStep = .authenticate
    /// The master password field (cleared after every attempt and on lock).
    var password = ""
    private(set) var isWorking = false
    /// Inline error of the authenticate step.
    private(set) var authError: ErrorPresentationModel?
    /// Incremented when the Touch ID prompt's password fallback is chosen; the screen focuses the
    /// password field on every change.
    private(set) var passwordFocusRequest = 0
    /// nil while unknown: the Touch ID button is offered until an attempt says otherwise.
    private(set) var touchIDStatus: BiometricUnlockStatus?
    private(set) var preview: EnvExportPreviewModel?
    /// Exported items that came from a share and are not verified on GitHub yet (§9.5).
    private(set) var unverifiedShareNames: [String] = []
    /// "owner/repo" (the file's header), or a folder's name.
    private(set) var repositoryName = ""
    /// The repository's own name, as the boards title a place ("api-service"); a folder's name.
    private(set) var placeName = ""
    private(set) var scopeTitle = ""
    /// The repository's clone folder, the save panel's starting folder.
    private(set) var suggestedDirectory: URL?
    private(set) var gitignoreState: EnvExportGitignoreState = .notApplicable
    var alert: ErrorPresentationModel?

    @ObservationIgnored private var authorization: EnvExportAuthorizationModel?
    @ObservationIgnored private let envFiles: EnvFileRepository
    @ObservationIgnored private let config: ConfigRepository
    @ObservationIgnored private let folders: FolderRepository
    @ObservationIgnored private let destinations: DestinationRepository
    @ObservationIgnored private let reauth: ReauthGate
    @ObservationIgnored private let session: VaultSession
    @ObservationIgnored private let tasks = TaskBag()

    /// - Parameters:
    ///   - envFiles: the repository that writes the file (tests pass one with fake git and
    ///     iCloud checks).
    ///   - touchIDStatus: the vault's Touch ID status, or nil when unknown (the button is then
    ///     offered and hidden after an unavailable answer).
    init(
        context: EnvExportContext,
        dependencies: FeatureDependencies,
        envFiles: EnvFileRepository,
        touchIDStatus: BiometricUnlockStatus?
    ) {
        place = context.place
        self.envFiles = envFiles
        config = dependencies.config
        folders = dependencies.folders
        destinations = dependencies.destinations
        reauth = dependencies.reauth
        session = dependencies.session
        self.touchIDStatus = touchIDStatus
        dependencies.actions.addLockObserver(self)
        loadHeader()
        observeItems()
    }

    /// The entry view's init: the app's repositories and the vault's Touch ID status.
    convenience init(context: EnvExportContext, dependencies: FeatureDependencies) {
        self.init(
            context: context,
            dependencies: dependencies,
            envFiles: dependencies.envFiles,
            touchIDStatus: dependencies.touchIDStatus()
        )
    }

    // MARK: - Authenticate

    var hasSomethingToExport: Bool {
        !(preview?.exportedNames.isEmpty ?? true)
    }

    var showsTouchIDButton: Bool {
        guard let touchIDStatus else { return true }
        return touchIDStatus == .available
    }

    /// A Touch ID state worth explaining next to the password field, or nil.
    var touchIDNotice: String? {
        switch touchIDStatus {
        case .passwordRequired(let reason):
            reason.localizedMessage
        case .unavailable(let reason):
            switch reason {
            case .lockout, .notAvailable, .notEnrolled, .passcodeNotSet: reason.localizedMessage
            case .notEnabled, .unsignedBuild: nil
            }
        case .available, nil:
            nil
        }
    }

    var canAuthenticateWithPassword: Bool {
        step == .authenticate && hasSomethingToExport && !password.isEmpty && !isWorking
    }

    var canAuthenticateWithTouchID: Bool {
        step == .authenticate && hasSomethingToExport && showsTouchIDButton && !isWorking
    }

    var defaultAction: EnvExportDefaultAction {
        switch step {
        case .authenticate:
            password.isEmpty && showsTouchIDButton ? .touchID : .password
        case .review:
            .chooseLocation
        case .confirmCloudSync:
            .chooseAnotherLocation
        case .done:
            if case .offered = gitignoreState { .addToGitignore } else { .done }
        }
    }

    func authenticateWithTouchID() async {
        guard canAuthenticateWithTouchID else { return }
        await authenticate(with: .biometrics(FeatureDependencies.reauthPrompt(for: .export)))
    }

    func authenticateWithPassword() async {
        guard canAuthenticateWithPassword else { return }
        let password = password
        self.password = ""
        await authenticate(with: .password(password))
    }

    // MARK: - Review and destination

    /// "Export N values" summary of the review step.
    var exportedCount: Int {
        preview?.exportedNames.count ?? 0
    }

    var valueMissingNames: [String] {
        preview?.valueMissingNames ?? []
    }

    var nameCollisions: [String] {
        preview?.nameCollisions ?? []
    }

    var suggestedFileName: String {
        EnvFilePanels.defaultExportFileName
    }

    /// The title's place (board Main2-Export): "api-service › production", the repository alone
    /// for its own scope, a folder's name; "" until the header loads.
    var placeTitle: String {
        if case .scope(_, let scope) = place, scope == .repository {
            return placeName
        }
        if placeName.isEmpty || scopeTitle.isEmpty {
            return placeName.isEmpty ? scopeTitle : placeName
        }
        return PlaceCopy.environmentPlace(repository: placeName, environment: scopeTitle)
    }

    /// The save panel returned `url`: checks iCloud and git, then writes, or asks first when the
    /// folder syncs to iCloud.
    func chooseDestination(_ url: URL) async {
        guard step == .review, !isWorking else { return }
        guard authorization?.isUsable == true else {
            reauthenticate()
            return
        }
        isWorking = true
        let existingFile: SecureFileWriter.ExistingFilePolicy =
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? .replace : .fail
        let destination = await envFiles.inspectDestination(url)
        isWorking = false
        let choice = EnvExportDestinationChoiceModel(fileURL: url, destination: destination, existingFile: existingFile)
        if destination.cloudSyncStatus.isSyncedToICloud {
            step = .confirmCloudSync(choice)
        } else {
            await write(choice)
        }
    }

    /// "Export Anyway" on the iCloud warning.
    func confirmCloudSyncExport() async {
        guard case .confirmCloudSync(let choice) = step, !isWorking else { return }
        await write(choice)
    }

    /// "Choose Another Location" on the iCloud warning.
    func chooseAnotherLocation() {
        guard case .confirmCloudSync = step else { return }
        step = .review
    }

    // MARK: - Done

    /// Appends the offered line to the repository's `.gitignore`.
    func addGitignoreEntry() {
        guard case .done(let outcome) = step, case .offered(let line) = gitignoreState,
              case .notIgnored(let root, let relativePath, _) = outcome.destination.gitExposure
        else { return }
        do {
            let added = try envFiles.addGitignoreEntry(relativePath: relativePath, repositoryRoot: root)
            gitignoreState = added ? .added(line: line) : .alreadyPresent
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Lifetime

    /// Drops the authorization and the typed password. Call it when the sheet closes.
    func discard() {
        authorization = nil
        password = ""
        tasks.cancelAll()
    }

    func vaultDidLock() {
        authorization = nil
        password = ""
        authError = nil
        if step != .authenticate {
            step = .authenticate
        }
    }

    // MARK: - Private

    private func authenticate(with credential: ReauthCredential) async {
        isWorking = true
        authError = nil
        defer { isWorking = false }
        do {
            authorization = try await reauth.authorizeEnvExport(with: credential, session: session)
            step = .review
        } catch let error as VaultError {
            handleAuthenticationError(error)
        } catch {
            authError = error.presentation
        }
    }

    private func handleAuthenticationError(_ error: VaultError) {
        switch error {
        case .cancelled:
            break
        case .passwordFallbackRequested:
            passwordFocusRequest += 1
        case .biometryUnavailable(let reason):
            touchIDStatus = .unavailable(reason)
            passwordFocusRequest += 1
        case .passwordRequired(let reason):
            touchIDStatus = .passwordRequired(reason)
            passwordFocusRequest += 1
        case .biometryInvalidated:
            touchIDStatus = .unavailable(.notEnabled)
            authError = error.presentation
        default:
            authError = error.presentation
        }
    }

    private func reauthenticate() {
        authorization = nil
        step = .authenticate
    }

    private func write(_ choice: EnvExportDestinationChoiceModel) async {
        guard let authorization else {
            reauthenticate()
            return
        }
        // Single use: whatever happens next, the next attempt needs a new check.
        self.authorization = nil
        isWorking = true
        defer { isWorking = false }
        let envFiles = envFiles
        let place = place
        let headerComments = [headerComment]
        do {
            let result = try await Task.detached {
                try envFiles.export(
                    place: place,
                    to: choice.fileURL,
                    authorization: authorization,
                    existingFile: choice.existingFile,
                    headerComments: headerComments
                )
            }.value
            gitignoreState = Self.gitignoreState(for: choice.destination.gitExposure)
            step = .done(EnvExportOutcomeModel(result: result, destination: choice.destination))
        } catch {
            alert = error.presentation
            step = .authenticate
        }
    }

    private static func gitignoreState(for exposure: GitExposureModel?) -> EnvExportGitignoreState {
        guard case .notIgnored(_, _, let line) = exposure else { return .notApplicable }
        return line.map { .offered(line: $0) } ?? .manual
    }

    /// The `# ` line at the top of the file (names only).
    private var headerComment: String {
        if case .destination = place {
            return String(
                localized: "envExport.file.header.destination",
                defaultValue: "Exported by FX Vault from \(repositoryName) (\(scopeTitle)). Plaintext values: never commit this file."
            )
        }
        if case .folder = place {
            return String(
                localized: "envExport.file.header.folder",
                defaultValue: "Exported by FX Vault from the folder \(repositoryName). Plaintext values: never commit this file."
            )
        }
        return String(
            localized: "envExport.file.header",
            defaultValue: "Exported by FX Vault from \(repositoryName) (\(scopeTitle)). Plaintext values: never commit this file."
        )
    }

    private func loadHeader() {
        do {
            switch place {
            case .scope(let repositoryID, let scope):
                let repository = try config.changeSet(repositoryID: repositoryID)?.repository
                repositoryName = repository?.fullName ?? ""
                placeName = repository?.name ?? ""
                suggestedDirectory = repository?.clonePath.map { URL(filePath: $0, directoryHint: .isDirectory) }
                scopeTitle = try config.scopes(repositoryID: repositoryID).first { $0.scope == scope }?.title ?? ""
            case .folder(let folderID):
                // The folder's name in the title; no clone folder to start the save panel in.
                repositoryName = try folders.folders().first { $0.id == folderID }?.name ?? ""
                placeName = repositoryName
                scopeTitle = ""
            case .destination(let destinationID):
                let destination = try destinations.destination(destinationID)
                let repository = try destination?.repositoryID.flatMap { try config.changeSet(repositoryID: $0)?.repository }
                repositoryName = repository?.fullName ?? ""
                placeName = repository?.name ?? ""
                suggestedDirectory = repository?.clonePath.map { URL(filePath: $0, directoryHint: .isDirectory) }
                scopeTitle = destination?.copyTargetTitle ?? ""
            }
        } catch {
            alert = error.presentation
        }
    }

    /// Keeps the preview and the unverified share names current while the sheet is open.
    private func observeItems() {
        switch place {
        case .scope(let repositoryID, let scope):
            let stream = config.observeItems(repositoryID: repositoryID, scope: scope)
            tasks.set("items", Task { [weak self] in
                do {
                    for try await items in stream {
                        self?.apply(items)
                    }
                } catch {
                    AppLog.ui.error("Export item observation ended")
                }
            })
        case .folder(let folderID):
            let stream = folders.observeItems(folderID: folderID)
            tasks.set("items", Task { [weak self] in
                do {
                    for try await _ in stream {
                        self?.apply([])
                    }
                } catch {
                    AppLog.ui.error("Export item observation ended")
                }
            })
        case .destination(let destinationID):
            let stream = destinations.observeItems(destinationID: destinationID)
            tasks.set("items", Task { [weak self] in
                do {
                    for try await _ in stream {
                        self?.apply([])
                    }
                } catch {
                    AppLog.ui.error("Export item observation ended")
                }
            })
        }
    }

    /// `items`: the scope's rows (a folder has no share provenance to warn about).
    private func apply(_ items: [ConfigItemModel]) {
        do {
            let preview = try envFiles.exportPreview(place: place)
            self.preview = preview
            unverifiedShareNames = Self.unverifiedShareNames(in: items, preview: preview)
        } catch {
            alert = error.presentation
        }
    }

    /// The exported items that came from a share and still carry the "from share, unverified"
    /// provenance (§9.5: "the .env export warning lists these items"). A variable left out for
    /// a secret of the same name, and a secret without a value, are not exported, so not listed.
    static func unverifiedShareNames(in items: [ConfigItemModel], preview: EnvExportPreviewModel) -> [String] {
        let exported = Set(preview.exportedNames)
        let collisions = Set(preview.nameCollisions)
        return items
            .filter { item in
                !item.isDeleted && item.hasValue && item.provenance == .share && exported.contains(item.name)
                    && !(item.kind == .variable && collisions.contains(item.name))
            }
            .map(\.name)
            .sorted()
    }
}
