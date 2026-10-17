import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// Opening a `.fxvault` file (§9.1 reader order, §9.5, §10 `ShareImportScreen`), from the
/// router or a Finder/AirDrop open:
/// 1. **Read** the file and check its header (formats 1 and 2) before any passphrase or key is
///    used.
/// 2. **Passphrase**: six words (any case or separator, §9.2), only for a passphrase file. A
///    wrong passphrase, a damaged file and an invalid package all show the one message "Wrong
///    passphrase or damaged file". A file sealed for teammates (v0.9.0) opens at once with this
///    Mac's keys; one sealed for others, from an unpaired sender or past its expiry cannot be
///    opened here (``Step/failed``).
/// 3. **Preview** with chips and choices (`ShareImportPlanEditor`); a repository that is not
///    in the vault gets a one-click import, then the package is planned again. A project share
///    (v0.9.0) shows its repositories (✓ in the vault, ⇣ imported from GitHub first, ✕ skipped),
///    each one's preview, its destinations and folders (``ProjectShareImportEditor``).
/// 4. **Apply** in one transaction; nothing syncs automatically, and a project share's rows the
///    remote does not have wait in Sync's From Files review. A project share then opens the
///    Overview of its first repository at its first stage.
///
/// A copy of a folder (v0.7.0) asks where it goes instead (``FolderDestinationModel``): saved as
/// a folder at once, or imported into a repository scope through the same preview.
///
/// Values never reach this view model: the draft (VaultData) holds them until applied, and is
/// discarded on close and on lock.
@Observable
final class ShareImportViewModel: LockObserving {
    enum Step: Equatable {
        case reading
        case passphrase
        case opening
        case preview
        case applying
        case done
        /// A copy of a folder: where it goes (v0.7.0).
        case folderDestination
        /// The folder copy was saved as a folder.
        case folderSaved
        /// A project share's repositories, destinations and folders (v0.9.0).
        case bundlePreview
        /// Importing a project share's ⇣ repositories from GitHub, then applying it.
        case bundleApplying
        /// A project share was imported.
        case bundleDone
        /// The file cannot be read or opened (nothing to retry here).
        case failed
    }

    private(set) var step: Step = .reading
    var passphrase = "" {
        didSet { passphraseError = nil }
    }
    /// The inline error under the passphrase field.
    private(set) var passphraseError: ErrorPresentationModel?
    private(set) var editor: ShareImportPlanEditor?
    private(set) var result: ShareImportResultModel?
    /// A project share's preview (v0.9.0).
    private(set) var bundleEditor: ProjectShareImportEditor?
    private(set) var bundleResult: ShareBundleImportResultModel?
    /// `owner/name` of the ⇣ repositories whose import from GitHub failed.
    private(set) var failedRepositories: [String] = []
    /// Who sent the file (verified for a teammates file).
    private(set) var sender: ShareFileSenderModel?
    /// Where a copy of a folder goes (v0.7.0).
    private(set) var destination: FolderDestinationModel?
    /// "Saved 3 items in Mobile App."
    private(set) var folderNotice: String?
    /// The folder copy was imported or saved before (a note, never a block).
    private(set) var wasFolderImported = false
    /// Why the file cannot be opened (``Step/failed``).
    private(set) var failure: ErrorPresentationModel?
    private(set) var isImportingRepository = false
    var alert: ErrorPresentationModel?
    let fileName: String

    @ObservationIgnored private let context: ShareImportContext
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let importer: ShareRepositoryImporter
    @ObservationIgnored private var file: ShareInspectedFileModel?
    @ObservationIgnored private var draft: ShareImportDraftModel?
    @ObservationIgnored private var folderDraft: ShareFolderDraftModel?
    @ObservationIgnored private var bundleDraft: ShareBundleDraftModel?

    init(context: ShareImportContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
        fileName = context.fileURL.lastPathComponent
        importer = ShareRepositoryImporter(
            github: dependencies.github,
            catalog: dependencies.catalog,
            isGitHubReady: dependencies.actions.isGitHubReady
        )
        dependencies.actions.addLockObserver(self)
    }

    // MARK: - Step 1: read

    /// Reads the file and checks its header (§9.1 steps 1–6) off the main actor. A teammates
    /// file opens right away.
    func start() async {
        guard step == .reading else { return }
        let sharing = dependencies.sharing
        let url = context.fileURL
        do {
            let inspected = try await Task.detached { try sharing.inspectFile(at: url) }.value
            file = inspected
            if inspected.needsPassphrase {
                step = .passphrase
            } else {
                await openFile(passphrase: nil)
            }
        } catch {
            failure = Self.presentation(of: error)
            step = .failed
        }
    }

    // MARK: - Step 2: passphrase

    /// False for a file sealed for teammates (v0.9.0): it opens without a passphrase.
    var needsPassphrase: Bool {
        file?.needsPassphrase ?? true
    }

    /// Words typed so far (letters only; any case or separator).
    var typedWordCount: Int {
        passphrase.split(whereSeparator: { !$0.isLetter }).count
    }

    var canOpen: Bool {
        step == .passphrase && typedWordCount == Limits.passphraseWordCount && file != nil
    }

    /// Decrypts, validates and plans the package.
    func open() async {
        guard canOpen else { return }
        await openFile(passphrase: passphrase)
    }

    private func openFile(passphrase: String?) async {
        guard let file else { return }
        step = .opening
        do {
            let opened = try await dependencies.sharing.openShareFile(
                file,
                passphrase: passphrase,
                checkGitHub: dependencies.checksGitHub
            )
            self.passphrase = ""
            sender = opened.sender
            switch opened.document {
            case .repository(let draft):
                show(draft)
            case .folder(let draft):
                showFolder(draft)
            case .bundle(let draft):
                showBundle(draft)
            }
        } catch {
            if file.needsPassphrase, !Self.cannotOpenHere(error) {
                passphraseError = Self.presentation(of: error)
                step = .passphrase
            } else {
                self.passphrase = ""
                failure = Self.presentation(of: error)
                step = .failed
            }
        }
    }

    /// Failures a passphrase cannot fix: the file is for other teammates, from an unpaired
    /// sender, or expired.
    private static func cannotOpenHere(_ error: SharingError) -> Bool {
        switch error {
        case .share(.notARecipient), .share(.senderNotTeammate), .share(.expired): true
        default: false
        }
    }

    // MARK: - Step 3: a folder's destination (v0.7.0)

    var canContinueFolder: Bool {
        step == .folderDestination && destination?.canContinue == true && folderDraft != nil
    }

    /// Saves the folder copy as a folder, or plans it for the chosen repository scope.
    func continueFolder() async {
        guard canContinueFolder, let destination, let folderDraft else { return }
        do {
            if let target = destination.saveTarget {
                let saved = try await dependencies.sharing.saveFolder(folderDraft, as: target, conflicts: destination.conflicts)
                self.folderDraft = nil
                folderNotice = FolderDestinationCopy.saved(saved, folderName: dependencies.folders.folderName(saved.folderID))
                step = .folderSaved
                dependencies.actions.openFolder(saved.folderID)
            } else if let target = destination.importTarget {
                let planned = try await dependencies.sharing.importDraft(
                    folderDraft,
                    into: target.repositoryID,
                    scope: target.scope,
                    checkGitHub: dependencies.checksGitHub
                )
                self.folderDraft = nil
                show(planned)
            }
        } catch {
            alert = error.presentation
        }
    }

    private func showFolder(_ opened: ShareFolderDraftModel) {
        folderDraft?.discard()
        folderDraft = opened
        wasFolderImported = opened.wasImported
        destination = FolderDestinationModel(manifest: opened.manifest, dependencies: dependencies)
        step = .folderDestination
    }

    // MARK: - Step 3: preview

    /// The package's `owner/name`.
    var repositoryFullName: String? {
        draft?.manifest.repository.fullName
    }

    /// The repository is not in the vault: offer the one-click import (§9.5).
    var needsRepositoryImport: Bool {
        editor?.blockReason == .repositoryNotImported
    }

    /// Imports the repository through an account with access, then plans the package again.
    /// The import goes through gh: offline it is disabled with the offline explanation.
    var isOnline: Bool {
        dependencies.connectivity.isOnline
    }

    func importRepository() async {
        guard needsRepositoryImport, isOnline, let draft, !isImportingRepository else { return }
        isImportingRepository = true
        defer { isImportingRepository = false }
        do {
            let repository = draft.manifest.repository
            _ = try await importer.importRepository(owner: repository.owner, name: repository.name)
            dependencies.actions.refresh(.catalog)
            show(try await dependencies.sharing.replan(draft, checkGitHub: dependencies.checksGitHub))
        } catch {
            alert = error.presentation
        }
    }

    var canApply: Bool {
        step == .preview && editor?.canApply == true && draft != nil
    }

    // MARK: - Step 4: apply

    func apply() async {
        guard canApply, let draft, let editor else { return }
        step = .applying
        do {
            result = try await dependencies.sharing.apply(
                draft,
                plan: editor.plan,
                confirmReplay: editor.confirmsReplay
            )
            self.draft = nil
            self.editor = nil
            step = .done
        } catch .planOutdated {
            alert = SharingError.planOutdated.presentation
            await replanAfterChange(draft)
        } catch {
            alert = error.presentation
            step = .preview
        }
    }

    // MARK: - Project shares (v0.9.0)

    var canApplyBundle: Bool {
        step == .bundlePreview && bundleEditor?.canApply == true && bundleDraft != nil
    }

    /// Imports the ⇣ repositories from GitHub when online (the user's choices are carried into
    /// the new plan), then applies the file in one transaction and opens the Overview.
    func applyBundle() async {
        guard canApplyBundle, var draft = bundleDraft, var editor = bundleEditor else { return }
        step = .bundleApplying
        do {
            if editor.needsRepositoryImport, isOnline {
                let imported = try await dependencies.sharing.importMissingRepositories(of: draft)
                dependencies.actions.refresh(.catalog)
                failedRepositories = imported.failedRepositories
                draft = imported.draft
                editor = ProjectShareImportEditor(draft: draft, replaying: editor)
                bundleDraft = draft
                bundleEditor = editor
            }
            let result = try await dependencies.sharing.applyBundle(draft, plan: editor.plan, confirmReplay: editor.confirmsReplay)
            bundleDraft = nil
            bundleEditor = nil
            bundleResult = result
            step = .bundleDone
            if let repositoryID = result.firstRepositoryID {
                dependencies.actions.openOverview(repositoryID, result.firstStage)
            }
        } catch .planOutdated {
            alert = SharingError.planOutdated.presentation
            await replanBundle(draft, replaying: editor)
        } catch {
            alert = error.presentation
            step = .bundlePreview
        }
    }

    private func showBundle(_ opened: ShareBundleDraftModel, replaying previous: ProjectShareImportEditor? = nil) {
        bundleDraft?.discard()
        bundleDraft = opened
        bundleEditor = ProjectShareImportEditor(draft: opened, replaying: previous)
        step = .bundlePreview
    }

    private func replanBundle(_ outdated: ShareBundleDraftModel, replaying previous: ProjectShareImportEditor) async {
        do {
            showBundle(try await dependencies.sharing.replanBundle(outdated, checkGitHub: dependencies.checksGitHub), replaying: previous)
        } catch {
            alert = error.presentation
            step = .bundlePreview
        }
    }

    // MARK: - Lifetime

    /// The sheet closed: discards the draft (wipes its values) and the typed passphrase.
    func close() {
        discard()
    }

    func vaultDidLock() {
        discard()
        switch step {
        case .done, .failed, .folderSaved, .bundleDone:
            break
        default:
            step = file?.needsPassphrase == false || file == nil ? .reading : .passphrase
        }
    }

    private func discard() {
        draft?.discard()
        draft = nil
        folderDraft?.discard()
        folderDraft = nil
        bundleDraft?.discard()
        bundleDraft = nil
        editor = nil
        bundleEditor = nil
        passphrase = ""
    }

    private func show(_ opened: ShareImportDraftModel) {
        draft?.discard()
        draft = opened
        editor = ShareImportPlanEditor(plan: opened.plan, repositoryFullName: opened.manifest.repository.fullName)
        step = .preview
    }

    private func replanAfterChange(_ outdated: ShareImportDraftModel) async {
        do {
            show(try await dependencies.sharing.replan(outdated, checkGitHub: dependencies.checksGitHub))
        } catch {
            alert = error.presentation
            step = .preview
        }
    }

    /// The single "Wrong passphrase or damaged file" for every read, decrypt or package failure.
    private static func presentation(of error: any Error) -> ErrorPresentationModel {
        if let sharing = error as? SharingError, sharing.isWrongPassphraseOrDamagedFile {
            return SharingError.wrongPassphraseOrDamagedFile
        }
        return error.presentation
    }
}
