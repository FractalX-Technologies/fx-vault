import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// Opening a `.fxvault` file (§9.1 reader order, §9.5, §10 `ShareImportScreen`), from the
/// router or a Finder/AirDrop open:
/// 1. **Read** the file and check its header before any passphrase is asked for.
/// 2. **Passphrase**: six words (any case or separator, §9.2). A wrong passphrase, a damaged
///    file and an invalid package all show the one message "Wrong passphrase or damaged file".
/// 3. **Preview** with chips and choices (`ShareImportPlanEditor`); a repository that is not
///    in the vault gets a one-click import, then the package is planned again.
/// 4. **Apply** in one transaction; nothing syncs automatically.
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
        /// The file cannot be read or its header is invalid (nothing to retry here).
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
    @ObservationIgnored private var file: ShareFileModel?
    @ObservationIgnored private var draft: ShareImportDraftModel?
    @ObservationIgnored private var folderDraft: ShareFolderDraftModel?

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

    /// Reads the file and checks its header (§9.1 steps 1–6) off the main actor.
    func start() async {
        guard step == .reading else { return }
        let sharing = dependencies.sharing
        let url = context.fileURL
        do {
            file = try await Task.detached { try sharing.readFile(at: url) }.value
            step = .passphrase
        } catch {
            failure = Self.presentation(of: error)
            step = .failed
        }
    }

    // MARK: - Step 2: passphrase

    /// Words typed so far (letters only; any case or separator).
    var typedWordCount: Int {
        passphrase.split(whereSeparator: { !$0.isLetter }).count
    }

    var canOpen: Bool {
        step == .passphrase && typedWordCount == Limits.passphraseWordCount && file != nil
    }

    /// Decrypts, validates and plans the package.
    func open() async {
        guard canOpen, let file else { return }
        step = .opening
        do {
            let opened = try await dependencies.sharing.openFileContents(
                file,
                passphrase: passphrase,
                checkGitHub: dependencies.checksGitHub
            )
            passphrase = ""
            switch opened {
            case .repository(let draft):
                show(draft)
            case .folder(let draft):
                showFolder(draft)
            }
        } catch {
            passphraseError = Self.presentation(of: error)
            step = .passphrase
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

    // MARK: - Lifetime

    /// The sheet closed: discards the draft (wipes its values) and the typed passphrase.
    func close() {
        discard()
    }

    func vaultDidLock() {
        discard()
        if step != .done, step != .failed, step != .folderSaved {
            step = file == nil ? .reading : .passphrase
        }
    }

    private func discard() {
        draft?.discard()
        draft = nil
        folderDraft?.discard()
        folderDraft = nil
        editor = nil
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
