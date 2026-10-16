import EnvTools
import Foundation
import VaultCore

/// Who reads a name, and when (the Overview's Cycle column, canvas board 2).
public enum StageOverviewCycle: String, Sendable, Hashable, CaseIterable, Comparable {
    /// Read by the deployed backend (a destination that is not public).
    case runtime
    /// Shipped in the client bundle (a public name in Vercel, a `public: true` var).
    case publicValue
    /// Read by the GitHub Actions workflow.
    case build
    /// Not decided (an extra item, or a name only some unclassified place has).
    case unknown

    public static func < (lhs: StageOverviewCycle, rhs: StageOverviewCycle) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ cycle: StageOverviewCycle) -> Int {
        allCases.firstIndex(of: cycle) ?? allCases.endIndex
    }
}

/// One column of the Overview: GitHub (repository level plus the environment named like the
/// stage) or a destination of that stage.
public enum StageOverviewColumnModel: Sendable, Hashable, Identifiable {
    /// `environment` is the environment named like the stage, or nil when the repository has none
    /// (repository-level items still count).
    case github(environment: EnvironmentModel?)
    case destination(DestinationModel)

    public var id: String {
        switch self {
        case .github: "github"
        case .destination(let destination): destination.id.uuidString
        }
    }
}

/// One cell: how a name stands in one column.
public enum StageOverviewCellModel: Sendable, Hashable {
    /// The column does not use the name.
    case notUsed
    case synced
    /// A pending add or change.
    case willPush
    /// Pending deletion.
    case willDelete
    /// A pending add whose value is missing (it cannot be sent).
    case valueMissing
    /// `fxvault.yml` sends the name here, but the column does not have it.
    case missing
    /// The column has the name, but `fxvault.yml` does not send it here.
    case extra
    /// Another column of the stage holds a different value under this name.
    case differs
    /// A public name whose value looks like a secret (R10).
    case blocked

    /// True for states that need attention (the manifest check lists them).
    public var needsAttention: Bool {
        switch self {
        case .missing, .extra, .differs, .blocked, .valueMissing: true
        case .notUsed, .synced, .willPush, .willDelete: false
        }
    }
}

/// One row of the Overview.
public struct StageOverviewRowModel: Sendable, Hashable, Identifiable {
    public let name: String
    public let cycle: StageOverviewCycle
    /// The most places any item of the row is linked to (the link chip), 0 when none.
    public let linkCount: Int
    /// One cell per column, in the columns' order.
    public let cells: [StageOverviewCellModel]
    /// The item each cell shows, or nil (to open it).
    public let itemIDs: [ConfigItemID?]

    public init(name: String, cycle: StageOverviewCycle, linkCount: Int, cells: [StageOverviewCellModel], itemIDs: [ConfigItemID?]) {
        self.name = name
        self.cycle = cycle
        self.linkCount = linkCount
        self.cells = cells
        self.itemIDs = itemIDs
    }

    public var id: String {
        name
    }
}

/// Something `fxvault.yml` asks for that the repository does not do (the manifest check).
public enum StageOverviewFindingModel: Sendable, Hashable, Identifiable {
    /// A name the manifest sends to a column that does not have it.
    case missing(name: String, column: String)
    /// A name a column has but the manifest does not send there.
    case extra(name: String, column: String)
    /// A public name with a secret-looking value.
    case blocked(name: String, column: String)
    /// `secret: true` in the manifest, but the item is a variable there.
    case kindMismatch(name: String, column: String)
    /// A manifest target with no destination in this repository yet ("Add Destination").
    case destinationNotAdded(target: String, location: ManifestLocation)

    public var id: String {
        switch self {
        case .missing(let name, let column): "missing|\(name)|\(column)"
        case .extra(let name, let column): "extra|\(name)|\(column)"
        case .blocked(let name, let column): "blocked|\(name)|\(column)"
        case .kindMismatch(let name, let column): "kind|\(name)|\(column)"
        case .destinationNotAdded(let target, _): "destination|\(target)"
        }
    }
}

/// The Overview of one stage (v0.8.0, tasks/todo.md R8).
public struct StageOverviewModel: Sendable, Hashable {
    public let stage: String
    public let columns: [StageOverviewColumnModel]
    public let rows: [StageOverviewRowModel]
    public let findings: [StageOverviewFindingModel]
    /// Whether a manifest was applied (Missing and Extra need one).
    public let usesManifest: Bool

    public init(stage: String, columns: [StageOverviewColumnModel], rows: [StageOverviewRowModel], findings: [StageOverviewFindingModel], usesManifest: Bool) {
        self.stage = stage
        self.columns = columns
        self.rows = rows
        self.findings = findings
        self.usesManifest = usesManifest
    }
}

/// `fxvault.yml` as read from the default branch.
public enum ManifestStateModel: Sendable, Hashable {
    /// The repository has no `fxvault.yml`.
    case none
    /// Read and parsed; `result.manifest` is nil when it has errors that leave no model.
    case read(sha: String, result: ManifestParseResult)
    /// It could not be read (offline, no access); `fxvault.yml` checks are off.
    case unavailable

    public var manifest: ManifestModel? {
        if case .read(_, let result) = self { return result.manifest }
        return nil
    }
}
