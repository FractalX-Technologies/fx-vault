/// What the app knows about the GitHub CLI (§10: a non-blocking status row on Welcome and on the
/// lock screen; the full `GHSetupScreen` arrives with Milestone 2).
enum GHStatusModel: Equatable {
    /// Detection is running.
    case checking
    /// Detection has not run in this build (placeholder until the gh repository is wired).
    case unknown
    /// gh was found and is new enough.
    case ready(version: String, path: String)
    /// No trusted gh executable was found.
    case notInstalled
    /// gh is older than the required version (D5).
    case outdated(found: String, required: String)
}

/// Detects gh. The live implementation comes from VaultData in Milestone 2 (GHLocator through a
/// repository); until then ``PendingGHStatusProbe`` reports ``GHStatusModel/unknown`` and the
/// status row stays hidden.
protocol GHStatusProbing: AnyObject {
    func probe() async -> GHStatusModel
}

/// Placeholder probe: never spawns a process.
final class PendingGHStatusProbe: GHStatusProbing {
    func probe() async -> GHStatusModel {
        .unknown
    }
}

/// A probe that returns a fixed status (previews and tests).
final class FixedGHStatusProbe: GHStatusProbing {
    private let status: GHStatusModel

    init(_ status: GHStatusModel) {
        self.status = status
    }

    func probe() async -> GHStatusModel {
        status
    }
}
