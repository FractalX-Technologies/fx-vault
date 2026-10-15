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
@Observable
final class ChatSaveViewModel: Identifiable, LockObserving {
    enum Step: Equatable {
        case preparing
        case preview
        case applying
        case done
        case failed
    }

    let id: ChatAttachmentID
    /// The card's names (shown in the header).
    let itemName: String
    private(set) var step: Step = .preparing
    private(set) var editor: ShareImportPlanEditor?
    private(set) var result: ShareImportResultModel?
    private(set) var failure: ErrorPresentationModel?
    private(set) var isImportingRepository = false
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let conversation: NearbyChatConversation
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let importer: ShareRepositoryImporter
    @ObservationIgnored private let onFinish: (_ saved: Bool) -> Void
    @ObservationIgnored private var draft: ShareImportDraftModel?
    @ObservationIgnored private var isFinished = false
    /// Set by ``close()``: a draft that arrives later (a preview still running when the chat
    /// ended or the vault locked) is discarded instead of shown.
    @ObservationIgnored private var isClosed = false

    /// - Parameter onFinish: called once, with whether the item was imported.
    init(
        card: ChatAttachmentCardModel,
        conversation: NearbyChatConversation,
        dependencies: FeatureDependencies,
        onFinish: @escaping (_ saved: Bool) -> Void
    ) {
        id = card.id
        itemName = card.offer.itemName
        self.conversation = conversation
        self.dependencies = dependencies
        self.onFinish = onFinish
        importer = ShareRepositoryImporter(
            github: dependencies.github,
            catalog: dependencies.catalog,
            isGitHubReady: dependencies.actions.isGitHubReady
        )
        dependencies.actions.addLockObserver(self)
    }

    /// Plans the received value against this vault (called when the sheet appears).
    func prepare() async {
        guard step == .preparing else { return }
        do {
            show(try await conversation.previewAttachment(id, checkGitHub: dependencies.checksGitHub))
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

    /// Done (after an import) or Cancel: wipes anything not imported and reports the outcome.
    func finish() {
        let saved = step == .done
        close()
        guard !isFinished else { return }
        isFinished = true
        onFinish(saved)
    }

    /// Discards the draft (wipes the value). Idempotent; the chat calls it when it ends.
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
