import Foundation
import Observation
import VaultCore
import VaultData

/// A shared scope (v0.6.0, S3, S7): its history and its members.
///
/// - **History**: every version, newest first, with author, Mac, time, note and the items it
///   changed. An item's versions show the short fingerprint every member sees; an older value
///   is revealed only after Touch ID or the master password (re-masked after
///   ``Timeouts/revealRemask``) and can be restored as a local change (its push is a new
///   version).
/// - **Members**: add paired teammates (they get the whole history); remove one (a new key for
///   the others, and the secrets to rotate). Both write the marker on GitHub, so they need gh.
@Observable
final class SpaceViewModel: LockObserving {
    enum Tab: Hashable, CaseIterable {
        case history
        case members
    }

    var tab: Tab = .history
    private(set) var detail: SpaceDetailModel?
    private(set) var history: [SpaceVersionSummaryModel] = []
    /// The item whose versions are listed under the history.
    private(set) var selectedItem: SpaceChangedItemModel?
    private(set) var itemHistory: [SpaceItemVersionModel] = []
    /// Revealed values by version, until re-masked.
    private(set) var revealed: [Int64: String] = [:]
    /// The version waiting for the master password (Touch ID unavailable or declined).
    private(set) var pendingReveal: Int64?
    var revealPassword = ""
    /// The member waiting for the removal confirmation.
    var pendingRemoval: SpaceMemberSummaryModel?
    private(set) var addableTeammates: [TeammateModel] = []
    private(set) var isWorking = false
    private(set) var notice: String?
    var alert: ErrorPresentationModel?

    let context: SpaceContext
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let tasks = TaskBag()

    init(context: SpaceContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
        dependencies.actions.addLockObserver(self)
    }

    func load() {
        do {
            let detail = try dependencies.spaces.detail(context.spaceID)
            self.detail = detail
            history = try dependencies.spaces.history(context.spaceID)
            let members = Set(detail.members.map(\.deviceID))
            addableTeammates = try dependencies.team.teammates().filter { !members.contains($0.id) }
            if let selectedItem {
                select(selectedItem)
            }
        } catch {
            alert = error.presentation
        }
    }

    /// "Production" or "Repository".
    var scopeName: String {
        guard let detail else { return "" }
        guard let id = detail.summary.scope.environmentID else { return SpaceCopy.repositoryScope }
        return (try? dependencies.config.scopes(repositoryID: detail.summary.repositoryID))?
            .first { $0.environment?.id == id }?.title ?? ""
    }

    var subtitle: String {
        guard let detail else { return "" }
        return SpaceCopy.subtitle(version: detail.summary.headVersion, members: detail.members.count)
    }

    var canChangeMembers: Bool {
        detail?.isMember == true && !isWorking && dependencies.actions.isGitHubReady() && dependencies.connectivity.isOnline
    }

    // MARK: - History

    func select(_ item: SpaceChangedItemModel) {
        selectedItem = item
        revealed = [:]
        do {
            itemHistory = try dependencies.spaces.itemHistory(context.spaceID, kind: item.kind, name: item.name)
        } catch {
            alert = error.presentation
        }
    }

    func closeItem() {
        selectedItem = nil
        itemHistory = []
        revealed = [:]
    }

    /// Reveals a version's value after Touch ID; falls back to the master password.
    func reveal(_ version: Int64) async {
        guard selectedItem != nil else { return }
        do {
            try await dependencies.reauth.authorize(
                .spaceHistory,
                with: .biometrics(FeatureDependencies.reauthPrompt(for: .spaceHistory))
            )
            show(version)
        } catch {
            if (error as? VaultError).map(Self.wantsPassword) == true {
                pendingReveal = version
            } else if !error.isCancellation {
                alert = error.presentation
            }
        }
    }

    /// The master password for ``pendingReveal``.
    func revealWithPassword() async {
        guard let version = pendingReveal, !revealPassword.isEmpty else { return }
        let typed = revealPassword
        revealPassword = ""
        do {
            try await dependencies.reauth.authorize(.spaceHistory, with: .password(typed))
            pendingReveal = nil
            show(version)
        } catch {
            alert = error.presentation
        }
    }

    func cancelPasswordReveal() {
        pendingReveal = nil
        revealPassword = ""
    }

    func hide(_ version: Int64) {
        revealed[version] = nil
    }

    private func show(_ version: Int64) {
        guard let item = selectedItem else { return }
        do {
            guard let value = try dependencies.spaces.value(context.spaceID, version: version, kind: item.kind, name: item.name) else {
                revealed[version] = SpaceCopy.noValue
                return
            }
            defer { value.wipe() }
            revealed[version] = value.utf8String() ?? ""
        } catch {
            alert = error.presentation
            return
        }
        let clock = dependencies.clock
        tasks.set("remask-\(version)", Task { [weak self] in
            try? await clock.sleep(for: Timeouts.revealRemask)
            guard !Task.isCancelled else { return }
            self?.revealed[version] = nil
        })
    }

    /// Stages an older value as a local change of the item.
    func restore(_ version: Int64) {
        guard let item = selectedItem else { return }
        do {
            try dependencies.spaces.restore(context.spaceID, version: version, kind: item.kind, name: item.name)
            notice = SpaceCopy.restored
        } catch {
            alert = error.presentation
        }
    }

    private static func wantsPassword(_ error: VaultError) -> Bool {
        switch error {
        case .passwordFallbackRequested, .biometryUnavailable, .biometryInvalidated, .passwordRequired: true
        default: false
        }
    }

    // MARK: - Members

    func add(_ teammateIDs: [String]) async {
        guard canChangeMembers, !teammateIDs.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await dependencies.spaces.addMembers(context.spaceID, teammateIDs: teammateIDs, me: dependencies.actions.spaceIdentity())
            dependencies.actions.spacesPublished()
            load()
        } catch {
            alert = error.presentation
        }
    }

    func confirmRemoval() async {
        guard let member = pendingRemoval, canChangeMembers else { return }
        pendingRemoval = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let checklist = try await dependencies.spaces.removeMembers(
                context.spaceID,
                deviceIDs: [member.deviceID],
                me: dependencies.actions.spaceIdentity()
            )
            notice = SpaceCopy.rotationChecklist(checklist.secretNames)
            dependencies.actions.spacesPublished()
            load()
        } catch {
            alert = error.presentation
        }
    }

    func vaultDidLock() {
        tasks.cancelAll()
        revealed = [:]
        revealPassword = ""
        pendingReveal = nil
    }
}
