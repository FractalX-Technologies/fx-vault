import Foundation
import Observation
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
        /// "Passphrase" or "Teammates: Ana, Ben".
        let recipients: String
        /// `owner/name` of each repository, in file order.
        let repositories: [String]
        let stages: [String]
        let secretCount: Int
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
    @ObservationIgnored private let team: TeamRepository
    @ObservationIgnored private let clock: any VaultClock
    @ObservationIgnored private let isUnlockedCheck: () -> Bool
    @ObservationIgnored private let tasks = TaskBag()

    convenience init(app: AppViewModel) {
        self.init(
            sharing: app.container.data.sharing,
            team: app.container.data.team,
            clock: app.container.clock,
            isUnlocked: { [weak app] in app?.phase == .unlocked }
        )
        app.addLockObserver(self)
    }

    init(sharing: SharingRepository, team: TeamRepository, clock: any VaultClock, isUnlocked: @escaping () -> Bool) {
        self.sharing = sharing
        self.team = team
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

    /// Builds the rows; teammates are named as this vault stores them now.
    func show(_ sent: [SentShareModel]) {
        let names = Dictionary(
            ((try? team.teammates()) ?? []).map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let now = clock.now
        entries = sent.map { share in
            Self.entry(share, names: names, now: now)
        }
    }

    static func entry(_ share: SentShareModel, names: [String: String], now: Date) -> EntryModel {
        let recipients: String = switch share.mode {
        case .passphrase: ProjectShareCopy.passphraseMode
        case .teammates: ProjectShareCopy.teammatesMode(share.recipientIDs.map { names[$0] ?? ProjectShareCopy.unknownTeammate($0) })
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
            secretCount: share.summary.secretCount,
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
