import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// "Save to my vault" for a secret or variable received in Nearby Chat: the same share import
/// preview and merge as a `.fxvault` file or a nearby share (§9.5, `ShareImportPlanEditor`,
/// `SharingRepository.apply`), so the value is re-encrypted under this vault's key and nothing
/// syncs automatically.
///
/// Values never reach this view model: ``NearbyChatConversation/previewAttachment(_:checkGitHub:)``
/// moves the received value into a VaultData draft, which is applied or discarded (wiped) on
/// Cancel, on close and on lock.
///
/// v0.4.0: a whole repository first asks which repository of this vault to import into (any
/// owner and name; the sender's repository is preselected when this vault has it), then shows
/// the same preview planned for that repository. Cancel before Continue keeps the received
/// values in the conversation (nothing was planned yet), so the card can still import them or
/// save them as a file.
@Observable
final class ChatSaveViewModel: Identifiable, LockObserving {
    /// How the sheet ended (``finish()``).
    enum Outcome: Equatable {
        case imported
        /// Nothing imported; the received values were wiped.
        case wiped
        /// A configuration closed before Continue: the received values stay in the conversation.
        case kept
    }

    enum Step: Equatable {
        /// A configuration: which repository of this vault (v0.4.0).
        case choosingTarget
        case preparing
        case preview
        case applying
        case done
        case failed
    }

    let id: ChatAttachmentID
    /// The card's names (shown in the header): the item, or the repository.
    let itemName: String
    /// A whole repository (v0.4.0).
    let isConfiguration: Bool
    private(set) var step: Step = .preparing
    /// The repositories a configuration can be imported into.
    private(set) var targets: [ChatImportTargetModel] = []
    var selectedTargetID: RepoID?
    private(set) var editor: ShareImportPlanEditor?
    private(set) var result: ShareImportResultModel?
    private(set) var failure: ErrorPresentationModel?
    private(set) var isImportingRepository = false
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let conversation: NearbyChatConversation
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let importer: ShareRepositoryImporter
    @ObservationIgnored private let onFinish: (Outcome) -> Void
    @ObservationIgnored private var draft: ShareImportDraftModel?
    @ObservationIgnored private var isFinished = false
    /// Set by ``close()``: a draft that arrives later (a preview still running when the chat
    /// ended or the vault locked) is discarded instead of shown.
    @ObservationIgnored private var isClosed = false

    /// - Parameter onFinish: called once, with how the sheet ended.
    init(
        card: ChatAttachmentCardModel,
        conversation: NearbyChatConversation,
        dependencies: FeatureDependencies,
        onFinish: @escaping (Outcome) -> Void
    ) {
        id = card.id
        itemName = card.offer.itemName ?? card.offer.repositoryFullName
        isConfiguration = card.offer.isConfiguration
        self.conversation = conversation
        self.dependencies = dependencies
        self.onFinish = onFinish
        importer = ShareRepositoryImporter(
            github: dependencies.github,
            catalog: dependencies.catalog,
            isGitHubReady: dependencies.actions.isGitHubReady
        )
        dependencies.actions.addLockObserver(self)
        if card.offer.isConfiguration {
            step = .choosingTarget
            loadTargets(for: card.offer)
        }
    }

    /// Plans the received value against this vault (called when the sheet appears). A
    /// configuration waits for ``importIntoSelectedTarget()``.
    func prepare() async {
        guard step == .preparing else { return }
        await preview(into: nil)
    }

    // MARK: - Target (v0.4.0)

    var selectedTarget: ChatImportTargetModel? {
        targets.first { $0.id == selectedTargetID }
    }

    var canChooseTarget: Bool {
        step == .choosingTarget && selectedTarget?.isEditable == true
    }

    /// Continue: plans the configuration for the chosen repository.
    func importIntoSelectedTarget() async {
        guard canChooseTarget, let target = selectedTarget else { return }
        step = .preparing
        // The sender's own repository keeps its GitHub id check; another one is a retarget.
        await preview(into: target.isSenderRepository ? nil : target.id)
    }

    private func loadTargets(for offer: ChatAttachmentOfferModel) {
        let hasEnvironments = !offer.manifest.repository.environments.isEmpty
        do {
            targets = try dependencies.chat.importTargets().map { repository in
                ChatImportTargetModel(
                    repository: repository,
                    senderFullName: offer.repositoryFullName,
                    hasEnvironments: hasEnvironments
                )
            }
            selectedTargetID = targets.first { $0.isSenderRepository && $0.isEditable }?.id
        } catch {
            failure = error.presentation
            step = .failed
        }
    }

    private func preview(into target: RepoID?) async {
        do {
            show(try await conversation.previewAttachment(id, into: target, checkGitHub: dependencies.checksGitHub))
        } catch {
            failure = error.presentation
            step = .failed
        }
    }

    // MARK: - Preview

    var repositoryFullName: String? {
        draft?.manifest.repository.fullName
    }

    /// The repository is not in this vault: offer the one-click import (§9.5).
    var needsRepositoryImport: Bool {
        step == .preview && editor?.blockReason == .repositoryNotImported
    }

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

    /// Imports the reviewed plan in one transaction.
    func apply() async {
        guard canApply, let draft, let editor else { return }
        step = .applying
        do {
            result = try await dependencies.sharing.apply(draft, plan: editor.plan, confirmReplay: editor.confirmsReplay)
            self.draft = nil
            self.editor = nil
            step = .done
        } catch .planOutdated {
            alert = SharingError.planOutdated.presentation
            do {
                show(try await dependencies.sharing.replan(draft, checkGitHub: dependencies.checksGitHub))
            } catch {
                alert = error.presentation
                step = .preview
            }
        } catch {
            alert = error.presentation
            step = .preview
        }
    }

    // MARK: - Lifetime

    /// Done (after an import) or Cancel: wipes anything not imported, except a configuration not
    /// planned yet (Cancel at the repository choice keeps it), and reports the outcome.
    func finish() {
        let outcome: Outcome = switch step {
        case .done: .imported
        case .choosingTarget: .kept
        case .preparing, .preview, .applying, .failed: .wiped
        }
        if outcome == .kept {
            isClosed = true
        } else {
            close()
        }
        guard !isFinished else { return }
        isFinished = true
        onFinish(outcome)
    }

    /// Discards the draft and the received value (wipes them). Idempotent; the chat calls it when
    /// it ends and a lock calls it too.
    func close() {
        isClosed = true
        draft?.discard()
        draft = nil
        editor = nil
        Task { [conversation, id] in
            await conversation.discardAttachment(id)
        }
    }

    func vaultDidLock() {
        close()
        if step != .done {
            step = .failed
        }
    }

    private func show(_ opened: ShareImportDraftModel) {
        guard !isClosed else {
            opened.discard()
            return
        }
        draft?.discard()
        draft = opened
        editor = ShareImportPlanEditor(plan: opened.plan, repositoryFullName: opened.manifest.repository.fullName)
        step = .preview
    }
}

/// A repository of this vault that a configuration received in chat can be imported into
/// (v0.4.0).
struct ChatImportTargetModel: Identifiable, Equatable {
    let id: RepoID
    let fullName: String
    /// Why this account may not add the configuration there (archived, or not admin when it has
    /// environments); nil when it may.
    let readOnlyReason: RepoCapabilityModel.ReadOnlyReason?
    /// The repository the configuration came from (same `owner/name`).
    let isSenderRepository: Bool

    /// - Parameter hasEnvironments: the configuration holds environments, which need admin;
    ///   repository-level items alone follow the repository-level permission.
    init(repository: RepoModel, senderFullName: String, hasEnvironments: Bool) {
        id = repository.id
        fullName = repository.fullName
        readOnlyReason = repository.capability.readOnlyReason(for: hasEnvironments ? .environment : .repository)
        isSenderRepository = repository.fullName.lowercased() == senderFullName.lowercased()
    }

    var isEditable: Bool {
        readOnlyReason == nil
    }
}
