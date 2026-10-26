import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// Preferences › Sharing (v0.9.0, tasks/todo.md P6): every project share file this Mac wrote,
/// newest first, with who it was for, when it expires and the names it carried, so a leaked file
/// tells what to rotate. Names only; values are never kept.
@Observable
final class SharingSettingsViewModel: LockObserving {
    /// One sent file, ready to show.
    struct EntryModel: Identifiable, Equatable {
        let id: SentShareID
        let createdAt: Date
        let expiresAt: Date
        let isExpired: Bool
        /// Nil for a passphrase file (every 1.0 file); a 0.9 row names its teammates
        /// ("Teammates: Removed teammate 0123…").
        let recipients: String?
        /// `owner/name` of each repository, in file order.
        let repositories: [String]
        let stages: [String]
        let counts: ShareItemCountModel
        /// Each place with its secret names, for "Rotate these".
        let places: [PlaceModel]
    }

    struct PlaceModel: Identifiable, Equatable {
        let id: String
        let title: String
        let secretNames: [String]
        let variableNames: [String]
    }

    private(set) var entries: [EntryModel] = []
    /// The entry waiting for "Remove from List".
    var pendingRemoval: EntryModel?
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let sharing: SharingRepository
    @ObservationIgnored private let clock: any VaultClock
    @ObservationIgnored private let isUnlockedCheck: () -> Bool
    @ObservationIgnored private let tasks = TaskBag()

    convenience init(app: AppViewModel) {
        self.init(
            sharing: app.container.data.sharing,
            clock: app.container.clock,
            isUnlocked: { [weak app] in app?.phase == .unlocked }
        )
        app.addLockObserver(self)
    }

    init(sharing: SharingRepository, clock: any VaultClock, isUnlocked: @escaping () -> Bool) {
        self.sharing = sharing
        self.clock = clock
        isUnlockedCheck = isUnlocked
        observe()
    }

    var isUnlocked: Bool {
        isUnlockedCheck()
    }

    private func observe() {
        let stream = sharing.observeSentShares()
        tasks.set("sent", Task { [weak self] in
            do {
                for try await sent in stream {
                    self?.show(sent)
                }
            } catch {
                AppLog.ui.error("Sent share observation ended")
            }
        })
    }

    /// Builds the rows.
    func show(_ sent: [SentShareModel]) {
        let now = clock.now
        entries = sent.map { share in
            Self.entry(share, now: now)
        }
    }

    static func entry(_ share: SentShareModel, now: Date) -> EntryModel {
        // 0.9 rows sealed for teammates outlive the teammates table (dropped in v15): ids only.
        let recipients: String? = switch share.mode {
        case .passphrase: nil
        case .teammates: ProjectShareCopy.teammatesMode(share.recipientIDs.map(ProjectShareCopy.unknownTeammate))
        }
        var repositories: [String] = []
        for place in share.summary.places {
            if let repository = place.repository, !repositories.contains(repository) {
                repositories.append(repository)
            }
        }
        let places = share.summary.places.enumerated().map { index, place in
            PlaceModel(
                id: "\(index)",
                title: title(of: place),
                secretNames: place.secretNames,
                variableNames: place.variableNames
            )
        }
        return EntryModel(
            id: share.id,
            createdAt: share.createdAt,
            expiresAt: share.expiresAt,
            isExpired: share.expiresAt <= now,
            recipients: recipients,
            repositories: repositories,
            stages: share.summary.stages,
            counts: ShareItemCountModel(
                secrets: share.summary.secretCount,
                variables: share.summary.places.reduce(0) { $0 + $1.variableNames.count }
            ),
            places: places
        )
    }

    private static func title(of place: SentSharePlaceModel) -> String {
        switch place.kind {
        case .repository:
            [place.repository, ProjectShareCopy.repositoryLevelPlace].compactMap { $0 }.joined(separator: " · ")
        case .environment, .destination:
            [place.repository, place.name].compactMap { $0 }.joined(separator: " · ")
        case .folder:
            [FolderCopy.eyebrow, place.name].compactMap { $0 }.joined(separator: " · ")
        }
    }

    // MARK: - Removing

    func requestRemoval(_ entry: EntryModel) {
        pendingRemoval = entry
    }

    func confirmRemoval() async {
        guard let entry = pendingRemoval else { return }
        pendingRemoval = nil
        do {
            try await sharing.deleteSentShare(entry.id)
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        pendingRemoval = nil
    }
}
