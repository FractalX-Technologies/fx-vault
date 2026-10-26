import Foundation
import SyncEngine
import VaultData

/// A line of the run's cards (board Sync-Progress): its group, its card's place and the changed
/// name (nil for the line about the place itself, its deployment branches).
struct SyncLineKey: Hashable {
    let group: SyncGroupID
    let place: String
    let name: String?
}

/// Where a change, and so its line, is in the run (board Sync-Progress: a check, a spinner, a
/// ring, a dash).
enum SyncLineState: Hashable {
    case waiting
    case writing
    case done
    case failed
    /// Not run: blocked, left out or the run stopped first.
    case skipped

    /// One line can stand for several changes (an environment's policy and its patterns): a
    /// failure wins, then the one being written; it is done when every change is.
    static func combined(_ states: [SyncLineState?]) -> SyncLineState {
        let known = states.compactMap(\.self)
        if known.contains(.failed) { return .failed }
        if known.contains(.writing) { return .writing }
        guard !known.isEmpty, known.count == states.count else {
            return known.isEmpty ? .waiting : .writing
        }
        return known.allSatisfy { $0 == .skipped } ? .skipped : .done
    }

    init(_ outcome: SyncChangeOutcomeModel) {
        switch outcome {
        case .succeeded: self = .done
        case .failed: self = .failed
        case .skipped, .blocked: self = .skipped
        }
    }

    init(_ outcome: DestinationChangeOutcome) {
        switch outcome {
        case .done, .unconfirmed: self = .done
        case .failed: self = .failed
        case .blocked, .skipped: self = .skipped
        }
    }

    init(_ outcome: OrgChangeOutcome) {
        switch outcome {
        case .done, .unconfirmed: self = .done
        case .failed: self = .failed
        case .blocked, .skipped: self = .skipped
        }
    }
}

/// One card of the run (board Sync-Progress): a place with its lines, or the deletions, last.
struct SyncProgressCardModel: Identifiable, Hashable {
    let id: String
    let systemImage: String
    let name: String
    let kind: String
    let lines: [SyncProgressLineModel]
}

/// One line of a run card: the state comes from ``key``; a blocked change is never written.
struct SyncProgressLineModel: Identifiable, Hashable {
    let key: SyncLineKey
    let name: String?
    let detail: String?
    var isBlocked = false

    var id: String {
        "\(key.group)|\(key.place)|\(name ?? "")|\(detail ?? "")|\(isBlocked)"
    }
}

/// The run's cards from the summary's (board Sync-Progress): the same places and lines, blocked
/// changes as lines that will not run, and the deletions gathered in a last card, since they run
/// after the writes.
enum SyncProgressPresentation {
    static let deletionsID = "deletions"

    static func cards(_ groups: [SyncSummaryRepoModel], includesDeletions: Bool) -> [SyncProgressCardModel] {
        var cards: [SyncProgressCardModel] = []
        var deletions: [SyncProgressLineModel] = []
        for group in groups where group.hasContent {
            for card in group.cards {
                var lines: [SyncProgressLineModel] = []
                for line in card.lines {
                    let key = SyncLineKey(group: group.id, place: card.place.id, name: line.name)
                    if line.symbol == .deleted {
                        deletions.append(SyncProgressLineModel(key: key, name: line.name, detail: card.place.name))
                    } else {
                        lines.append(SyncProgressLineModel(key: key, name: line.name, detail: line.detail))
                    }
                }
                for issue in card.blocked + card.remoteChanged {
                    lines.append(SyncProgressLineModel(
                        key: SyncLineKey(group: group.id, place: card.place.id, name: issue.name ?? issue.title),
                        name: issue.name ?? issue.title,
                        detail: SyncCopy.blockedDetail(issue.reason),
                        isBlocked: true
                    ))
                }
                guard !lines.isEmpty else { continue }
                cards.append(SyncProgressCardModel(
                    id: "\(group.id)|\(card.place.id)",
                    systemImage: card.place.systemImage,
                    name: card.place.name,
                    kind: card.place.kind,
                    lines: lines
                ))
            }
        }
        if includesDeletions, !deletions.isEmpty {
            cards.append(SyncProgressCardModel(
                id: deletionsID,
                systemImage: "exclamationmark.triangle",
                name: SyncCopy.deletionsCardTitle,
                kind: SyncCopy.deletionsCardKind,
                lines: deletions
            ))
        }
        return cards
    }

    /// The line of a GitHub change: its scope and name; a policy, pattern or rename change is the
    /// line about the environment itself. Repository creation and environment deletion have
    /// none (the card's sentence says them).
    static func key(_ change: ConfigChangeModel, group: SyncGroupID) -> SyncLineKey? {
        let name: String?
        switch change.operation {
        case .setItem(let set): name = set.name
        case .deleteItem(let delete): name = delete.name
        case .upsertEnvironment, .reconcileBranchPatterns, .renameEnvironment: name = nil
        case .createRepository, .deleteEnvironment: return nil
        }
        return SyncLineKey(group: group, place: change.scope.journalKey, name: name)
    }
}

/// The finished run when nothing failed (board Sync-Done): what synced, where, and what stays
/// pending (blocked or left out).
struct SyncDoneModel: Hashable {
    let syncedCount: Int
    /// The places' names, in summary order.
    let places: [String]
    let pending: [SyncIssueModel]
    let warnings: [String]
}
