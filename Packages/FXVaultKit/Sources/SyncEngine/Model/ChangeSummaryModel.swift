import Foundation
import VaultCore

/// The sync summary (tasks/todo.md §7.2) as data: names, kinds and counts, never values.
///
/// Packages ship no user-facing text (D24): the app renders this model with its localized
/// strings, either directly or through ``ChangeSummaryRenderer`` with a localized
/// ``ChangeSummaryVocabulary``.
public struct ChangeSummaryModel: Sendable, Hashable {
    public var repositories: [RepoChangeSummaryModel]
    /// FX Vault's own hourly write budget (local throttle, not GitHub's quota), when known.
    public var writeBudget: WriteBudgetModel?

    public init(repositories: [RepoChangeSummaryModel], writeBudget: WriteBudgetModel? = nil) {
        self.repositories = repositories
        self.writeBudget = writeBudget
    }

    /// Sum of every repository's pending count.
    public var pendingCount: Int {
        repositories.map(\.pendingCount).reduce(0, +)
    }

    /// Sum of every repository's blocked entries (remote-changed ones included).
    public var blockedCount: Int {
        repositories.map { $0.blocked.count + $0.remoteChanged.count }.reduce(0, +)
    }
}

/// Writes used in the current hour out of FX Vault's limit (D12).
public struct WriteBudgetModel: Sendable, Hashable {
    public var used: Int
    public var limit: Int

    public init(used: Int, limit: Int = Limits.writesPerHour) {
        self.used = used
        self.limit = limit
    }
}

/// One repository's block of the summary.
public struct RepoChangeSummaryModel: Sendable, Hashable, Identifiable {
    public var id: RepoID
    /// `owner/name`.
    public var fullName: String
    /// Present when the repository will be created.
    public var newRepository: NewRepositorySummaryModel?
    /// Repository scope first, then environments by name.
    public var scopes: [ScopeChangeSummaryModel]
    /// Blocked entries other than ``remoteChanged``; dependent changes are folded into the
    /// change they depend on.
    public var blocked: [BlockedSummaryModel]
    /// Items and environments changed on GitHub since the last check (D27).
    public var remoteChanged: [RemoteChangedSummaryModel]
    /// The repository's "Sync N" count.
    public var pendingCount: Int
    /// Notes such as a case-only environment rename.
    public var notes: [ChangeNoteModel]

    public init(
        id: RepoID,
        fullName: String,
        newRepository: NewRepositorySummaryModel?,
        scopes: [ScopeChangeSummaryModel],
        blocked: [BlockedSummaryModel],
        remoteChanged: [RemoteChangedSummaryModel],
        pendingCount: Int,
        notes: [ChangeNoteModel]
    ) {
        self.id = id
        self.fullName = fullName
        self.newRepository = newRepository
        self.scopes = scopes
        self.blocked = blocked
        self.remoteChanged = remoteChanged
        self.pendingCount = pendingCount
        self.notes = notes
    }
}

/// `(new repository · private · README · Swift .gitignore · MIT)`.
public struct NewRepositorySummaryModel: Sendable, Hashable {
    public var visibility: RepoVisibility
    public var addsReadme: Bool
    public var gitignoreTemplate: String?
    public var licenseTemplate: String?

    public init(visibility: RepoVisibility, addsReadme: Bool, gitignoreTemplate: String?, licenseTemplate: String?) {
        self.visibility = visibility
        self.addsReadme = addsReadme
        self.gitignoreTemplate = gitignoreTemplate
        self.licenseTemplate = licenseTemplate
    }
}

/// Which scope a summary line or entry belongs to.
public enum ScopeLabelModel: Sendable, Hashable {
    case repository
    /// The environment's display name (the new name for a rename).
    case environment(String)
}

/// One scope line: environment-level change, policy, item counts and item names.
public struct ScopeChangeSummaryModel: Sendable, Hashable {
    public var scope: RemoteScopeKeyModel
    public var label: ScopeLabelModel
    public var environmentChange: EnvironmentChangeSummaryModel?
    /// The desired policy, shown when it is created, changed or its patterns change.
    public var policy: PolicySummaryModel?
    /// Items in display order (added, renamed, modified, deleted; then by name).
    public var items: [ItemChangeSummaryModel]

    public init(
        scope: RemoteScopeKeyModel,
        label: ScopeLabelModel,
        environmentChange: EnvironmentChangeSummaryModel?,
        policy: PolicySummaryModel?,
        items: [ItemChangeSummaryModel]
    ) {
        self.scope = scope
        self.label = label
        self.environmentChange = environmentChange
        self.policy = policy
        self.items = items
    }

    public var addedCount: Int {
        items.filter { $0.change == .added }.count
    }

    public var modifiedCount: Int {
        items.filter { $0.change == .modified }.count
    }

    public var deletedCount: Int {
        items.filter { $0.change == .deleted }.count
    }

    public var renamedCount: Int {
        items.filter {
            if case .renamed = $0.change { return true }
            return false
        }.count
    }
}

/// What happens to the environment itself.
public enum EnvironmentChangeSummaryModel: Sendable, Hashable {
    case created
    case policyChanged
    /// `staging → stage   renamed (recreated on GitHub)`.
    case renamed(from: String)
    /// `qa   deleted — contents fetched live at confirmation`.
    case deleted
}

/// `policy: custom (release/*)`.
public struct PolicySummaryModel: Sendable, Hashable {
    public var kind: BranchPolicyKind
    /// Active pattern texts when custom, in row order.
    public var patterns: [String]

    public init(kind: BranchPolicyKind, patterns: [String]) {
        self.kind = kind
        self.patterns = patterns
    }
}

/// `+ SENTRY_DSN (secret)`.
public struct ItemChangeSummaryModel: Sendable, Hashable {
    public var name: String
    public var kind: ConfigKind
    public var change: Change

    public init(name: String, kind: ConfigKind, change: Change) {
        self.name = name
        self.kind = kind
        self.change = change
    }

    public enum Change: Sendable, Hashable {
        case added
        case modified
        case deleted
        case renamed(from: String)

        var displayRank: Int {
            switch self {
            case .added: 0
            case .renamed: 1
            case .modified: 2
            case .deleted: 3
            }
        }
    }
}

/// `Blocked: DB_PASSWORD in production — value missing locally`.
public struct BlockedSummaryModel: Sendable, Hashable {
    /// The item name, or the environment name for an environment change.
    public var name: String
    /// Nil for an environment-level change.
    public var kind: ConfigKind?
    public var scope: ScopeLabelModel
    public var reason: ChangeBlockReason

    public init(name: String, kind: ConfigKind?, scope: ScopeLabelModel, reason: ChangeBlockReason) {
        self.name = name
        self.kind = kind
        self.scope = scope
        self.reason = reason
    }
}

/// `Changed on GitHub since your last check: API_TOKEN (Repository)`.
public struct RemoteChangedSummaryModel: Sendable, Hashable {
    public var name: String
    public var kind: ConfigKind?
    public var scope: ScopeLabelModel

    public init(name: String, kind: ConfigKind?, scope: ScopeLabelModel) {
        self.name = name
        self.kind = kind
        self.scope = scope
    }
}
