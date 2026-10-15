import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// "Attach secret or variable…" in Nearby Chat: **re-authentication first** (Touch ID or the
/// master password, `ReauthGate.authorizeShare(.nearbySend)`), then one item from the vault is
/// chosen and offered. Only names are listed and sent; the value is decrypted only if the other
/// person saves it.
///
/// The authorization is single-use and handed to ``onPick`` with the chosen item; the typed
/// password and any unused authorization are dropped on close and on lock.
@Observable
final class ChatAttachmentPickerViewModel: Identifiable, LockObserving {
    enum Step: Equatable {
        case authenticating
        case choosing
        case sending
    }

    let id = UUID()
    let reauth: ShareReauthModel
    private(set) var step: Step = .authenticating
    var query = ""
    var selectedID: ConfigItemID?
    private(set) var items: [ChatAttachableItemModel] = []
    private(set) var loadError: ErrorPresentationModel?

    @ObservationIgnored private let chat: ChatRepository
    @ObservationIgnored private let onPick: (ChatAttachableItemModel, ShareAuthorizationModel) async -> Void

    /// - Parameter onPick: offers the item with the authorization (consumed by the offer).
    init(
        dependencies: FeatureDependencies,
        onPick: @escaping (ChatAttachableItemModel, ShareAuthorizationModel) async -> Void
    ) {
        chat = dependencies.chat
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
            loadError = nil
        } catch {
            items = []
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

    var canSend: Bool {
        step == .choosing && selectedItem != nil && reauth.isAuthorized
    }

    /// Offers the selected item (names only) with the single-use authorization.
    func send() async {
        guard canSend, let item = selectedItem, let authorization = reauth.takeAuthorization() else { return }
        step = .sending
        await onPick(item, authorization)
    }

    // MARK: - Lifetime

    /// The sheet closed: drops the typed password and an unused authorization.
    func close() {
        reauth.reset()
        items = []
    }

    func vaultDidLock() {
        close()
        step = .authenticating
    }
}
