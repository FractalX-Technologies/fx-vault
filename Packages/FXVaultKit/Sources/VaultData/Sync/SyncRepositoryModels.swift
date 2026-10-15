import EnvTools
import Foundation
import os
import SyncEngine
import VaultCore

/// What the Sync sheet shows before the user confirms (§7.2, §7.3): the preflight plus the
/// variables that look like credentials (§5.13), which the user confirms before the run.
public struct SyncReviewModel: Sendable, Hashable {
    public var preflight: SyncPreflightModel
    /// Executable variable sets whose name or value looks like a credential. The app asks
    /// "Push these as variables anyway?" before ``SyncRepository/startRun(_:includeDeletions:cloneFolder:)``.
    public var credentialWarnings: [SyncCredentialWarningModel]

    public init(preflight: SyncPreflightModel, credentialWarnings: [SyncCredentialWarningModel]) {
        self.preflight = preflight
        self.credentialWarnings = credentialWarnings
    }

    /// The §7.2 summary.
    public var summary: ChangeSummaryModel {
        preflight.summary
    }

    /// "Review N deletions…" (§7.5).
    public var deletionCount: Int {
        preflight.deletionCount
    }
}

/// A variable about to be pushed that looks like a credential (names only, never the value).
public struct SyncCredentialWarningModel: Sendable, Hashable, Identifiable {
    public var changeID: String
    public var repositoryID: RepoID
    public var itemID: ConfigItemID
    public var name: String
    /// The remote environment name; nil at repository level.
    public var environmentName: String?
    public var reasons: [CredentialReason]

    public init(
        changeID: String,
        repositoryID: RepoID,
        itemID: ConfigItemID,
        name: String,
        environmentName: String?,
        reasons: [CredentialReason]
    ) {
        self.changeID = changeID
        self.repositoryID = repositoryID
        self.itemID = itemID
        self.name = name
        self.environmentName = environmentName
        self.reasons = reasons
    }

    public var id: String {
        changeID
    }
}

/// The end of one run: the §7.4 result plus the clones the run requested (§7.3 step 8).
public struct SyncRunOutcomeModel: Sendable, Hashable {
    public var result: SyncResultModel
    public var clones: [RepoCloneOutcomeModel]

    public init(result: SyncResultModel, clones: [RepoCloneOutcomeModel]) {
        self.result = result
        self.clones = clones
    }
}

/// The journal's latest run, for the "last sync report" (D28, §6 retention keeps it).
public struct SyncRunReportModel: Sendable, Hashable {
    public var runID: SyncRunID
    /// Every journaled gh command of the run, in the order it was written. Names only.
    public var entries: [SyncJournalEntryModel]

    public init(runID: SyncRunID, entries: [SyncJournalEntryModel]) {
        self.runID = runID
        self.entries = entries
    }

    public var startedAt: Date? {
        entries.map(\.startedAt).min()
    }

    public var finishedAt: Date? {
        entries.compactMap(\.finishedAt).max()
    }

    /// Entries in `state`.
    public func entries(in state: SyncJournalOutcomeState) -> [SyncJournalEntryModel] {
        entries.filter { $0.state == state }
    }

    /// Entries still `in_flight` or `indeterminate` (launch reconciliation resolves them).
    public var unresolved: [SyncJournalEntryModel] {
        entries.filter { SyncJournalOutcomeState.unresolved.contains($0.state) }
    }
}

/// One running Sync (§7.3, §7.4): its progress stream, cancellation and final outcome.
///
/// Created by ``SyncRepository/startRun(_:includeDeletions:cloneFolder:)``; the run starts
/// immediately. ``cancel()`` is synchronous and callable from any thread (sleep, screen lock,
/// the Cancel button): it stops after the gh command in flight. The app holds a
/// `SyncActivityAssertion` until ``outcome()`` returns.
public final class SyncRunHandle: Sendable {
    public let runID: SyncRunID
    /// Progress events; ends after `.finished`.
    public let progress: AsyncStream<SyncProgressEventModel>
    private let executor: SyncExecutor
    private let task: Task<SyncRunOutcomeModel, Never>
    private let finished: OSAllocatedUnfairLock<Bool>

    init(
        executor: SyncExecutor,
        plan: SyncPlanModel,
        cloner: (any RepoCloning)?,
        cloneFolder: URL?
    ) {
        runID = plan.runID
        progress = executor.progress
        self.executor = executor
        let finished = OSAllocatedUnfairLock(initialState: false)
        self.finished = finished
        task = Task {
            let result: SyncResultModel
            do {
                result = try await executor.run(plan)
            } catch {
                // `run` throws only `.alreadyRunning`, impossible for a fresh executor.
                result = SyncResultModel(runID: plan.runID, repositories: [], stopReason: .persistenceFailed, warnings: [])
            }
            let clones = await Self.clone(result, cloner: cloner, folder: cloneFolder)
            finished.withLock { $0 = true }
            return SyncRunOutcomeModel(result: result, clones: clones)
        }
    }

    /// Stops the run after the gh command in flight.
    public func cancel() {
        executor.cancel()
    }

    /// Waits for the run (and its clones) to finish.
    public func outcome() async -> SyncRunOutcomeModel {
        await task.value
    }

    /// True once ``outcome()`` is available.
    public var isFinished: Bool {
        finished.withLock { $0 }
    }

    /// Clones every repository the run created with "clone after" (§7.3 step 8, §8 D3).
    private static func clone(
        _ result: SyncResultModel,
        cloner: (any RepoCloning)?,
        folder: URL?
    ) async -> [RepoCloneOutcomeModel] {
        var outcomes: [RepoCloneOutcomeModel] = []
        for warning in result.warnings {
            guard case .cloneRequested(let repositoryID) = warning else { continue }
            guard let cloner, let folder else {
                outcomes.append(RepoCloneOutcomeModel(repositoryID: repositoryID, state: .notAttempted))
                continue
            }
            do {
                let url = try await cloner.clone(repositoryID, into: folder)
                outcomes.append(RepoCloneOutcomeModel(repositoryID: repositoryID, state: .cloned(url)))
            } catch {
                outcomes.append(RepoCloneOutcomeModel(repositoryID: repositoryID, state: .failed(error)))
            }
        }
        return outcomes
    }
}
