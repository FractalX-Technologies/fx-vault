import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// "Attach…" in Nearby Chat: **re-authentication first** (Touch ID or the master password,
/// `ReauthGate.authorizeShare(.nearbySend)`), then one item, or (v0.4.0) a whole repository,
/// is chosen and offered. Only names are listed and sent; values are decrypted only if the
/// other person saves them.
///
/// The authorization is single-use and handed to ``onPick`` with the choice; the typed password
/// and any unused authorization are dropped on close and on lock.
@Observable
final class ChatAttachmentPickerViewModel: Identifiable, LockObserving {
    enum Step: Equatable {
        case authenticating
        case choosing
        case sending
    }

    /// One secret or variable, or a whole repository (v0.4.0).
    enum Mode: Hashable {
        case item
        case repository
    }

    let id = UUID()
    let reauth: ShareReauthModel
    /// False with a teammate on FX Vault 0.3 or earlier: the Repository tab explains it.
    let acceptsRepositories: Bool
    private(set) var step: Step = .authenticating
    var mode: Mode = .item
    var query = ""
    var selectedID: ConfigItemID?
    var selectedRepositoryID: RepoID?
    private(set) var items: [ChatAttachableItemModel] = []
    private(set) var repositories: [ChatAttachableRepositoryModel] = []
    private(set) var loadError: ErrorPresentationModel?

    @ObservationIgnored private let chat: ChatRepository
    @ObservationIgnored private let onPick: (ChatAttachmentChoiceModel, ShareAuthorizationModel) async -> Void

    /// - Parameters:
    ///   - acceptsRepositories: whether the teammate's FX Vault can receive a whole repository.
    ///   - onPick: offers the choice with the authorization (consumed by the offer).
    init(
        dependencies: FeatureDependencies,
        acceptsRepositories: Bool = false,
        onPick: @escaping (ChatAttachmentChoiceModel, ShareAuthorizationModel) async -> Void
    ) {
        chat = dependencies.chat
        self.acceptsRepositories = acceptsRepositories
        self.onPick = onPick
        reauth = ShareReauthModel(
            purpose: .nearbySend,
            reauth: dependencies.reauth,
            session: dependencies.session,
            touchIDStatus: dependencies.touchIDStatus()
        )
        dependencies.actions.addLockObserver(self)
    }

    // MARK: - Re-authentication

    /// The automatic Touch ID attempt when the sheet appears (silent on Macs without it).
    func begin() async {
        guard step == .authenticating else { return }
        if await reauth.authorizeWithTouchID(automatic: true) {
            didAuthenticate()
        }
    }

    func authenticateWithTouchID() async {
        if await reauth.authorizeWithTouchID() {
            didAuthenticate()
        }
    }

    func authenticateWithPassword() async {
        if await reauth.authorizeWithPassword() {
            didAuthenticate()
        }
    }

    private func didAuthenticate() {
        step = .choosing
        do {
            items = try chat.attachableItems()
            repositories = try chat.attachableRepositories()
            loadError = nil
        } catch {
            items = []
            repositories = []
            loadError = error.presentation
        }
    }

    // MARK: - Choosing

    /// The items matching ``query`` (name, repository or environment), grouped by scope.
    var sections: [ChatPickerSectionModel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? items : items.filter { item in
            [item.name, item.repositoryFullName, item.environmentName ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        var sections: [ChatPickerSectionModel] = []
        for item in matching {
            if let last = sections.last,
               last.repositoryFullName == item.repositoryFullName,
               last.environmentName == item.environmentName {
                sections[sections.count - 1] = ChatPickerSectionModel(
                    repositoryFullName: last.repositoryFullName,
                    environmentName: last.environmentName,
                    items: last.items + [item]
                )
            } else {
                sections.append(ChatPickerSectionModel(
                    repositoryFullName: item.repositoryFullName,
                    environmentName: item.environmentName,
                    items: [item]
                ))
            }
        }
        return sections
    }

    var selectedItem: ChatAttachableItemModel? {
        items.first { $0.id == selectedID }
    }

    /// The repositories matching ``query`` (v0.4.0).
    var matchingRepositories: [ChatAttachableRepositoryModel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? repositories : repositories.filter { $0.fullName.localizedCaseInsensitiveContains(needle) }
    }

    var selectedRepository: ChatAttachableRepositoryModel? {
        repositories.first { $0.id == selectedRepositoryID }
    }

    /// What Attach would send in the current tab, or nil.
    var choice: ChatAttachmentChoiceModel? {
        switch mode {
        case .item:
            selectedItem.map(ChatAttachmentChoiceModel.item)
        case .repository:
            acceptsRepositories ? selectedRepository.map(ChatAttachmentChoiceModel.repository) : nil
        }
    }

    var canSend: Bool {
        step == .choosing && choice != nil && reauth.isAuthorized
    }

    /// Offers the choice (names only) with the single-use authorization.
    func send() async {
        guard canSend, let choice, let authorization = reauth.takeAuthorization() else { return }
        step = .sending
        await onPick(choice, authorization)
    }

    // MARK: - Lifetime

    /// The sheet closed: drops the typed password and an unused authorization.
    func close() {
        reauth.reset()
        items = []
        repositories = []
    }

    func vaultDidLock() {
        close()
        step = .authenticating
    }
}
