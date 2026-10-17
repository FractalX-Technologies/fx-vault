import Foundation
import GitHubKit
import SyncEngine
import VaultCore
import VaultData

/// A running sync as the Sync sheet drives it: progress events, Cancel and the final outcome.
/// `SyncRunHandle` is the live implementation; tests script their own run.
nonisolated protocol SyncRunControlling: AnyObject, Sendable {
    /// Progress events; ends after `.finished`.
    var progress: AsyncStream<SyncProgressEventModel> { get }
    /// Stops the run after the gh command in flight.
    func cancel()
    /// Waits for the run and the clones it requested.
    func outcome() async -> SyncRunOutcomeModel
}

nonisolated extension SyncRunHandle: SyncRunControlling {}

/// What ``SyncViewModel`` needs from VaultData (`SyncRepository`, the account scope status and
/// `RepoCloning`). The live implementation is ``LiveSyncService``; view-model tests use a fake.
nonisolated protocol SyncServicing: Sendable {
    /// §7.3 preflight of `repositoryIDs` (nil: every repository with pending changes), taking
    /// over the stale pushes of `spaceTakeovers` (Q3).
    func preflight(repositoryIDs: [RepoID]?, spaceTakeovers: Set<SpaceID>) async throws(SyncRepositoryError) -> SyncReviewModel
    /// §7.5 live contents of every environment being deleted. Never throws.
    func deletionPreview(for review: SyncReviewModel) async -> [RepoDeletionPreviewModel]
    /// Plans and starts the run (§7.3, §7.4). `spaceReason` goes into the shared versions.
    /// `includeHeld` (v0.9.0): the share files the From Files review included; their holds are
    /// released and their rows run.
    func startRun(
        _ review: SyncReviewModel,
        includeDeletions: Bool,
        includeHeld: Set<SharePackageID>,
        cloneFolder: URL?,
        spaceReason: String?
    ) async throws(SyncRepositoryError) -> any SyncRunControlling
    /// Clones a repository a run created (retry, or a clone folder chosen afterwards).
    func clone(_ repositoryID: RepoID, into folder: URL) async throws(RepoCreationError) -> URL
}

/// ``SyncServicing`` over the app's single `SyncRepository`, `GitHubEnvironmentRepository` and
/// cloner (UI feature contract: clone only through `FeatureDependencies.cloner`).
nonisolated struct LiveSyncService: SyncServicing {
    let sync: SyncRepository
    let github: GitHubEnvironmentRepository
    let cloner: any RepoCloning

    func preflight(repositoryIDs: [RepoID]?, spaceTakeovers: Set<SpaceID>) async throws(SyncRepositoryError) -> SyncReviewModel {
        let scopeStatus = await scopeStatus()
        return try await sync.preflight(repositoryIDs: repositoryIDs, scopeStatus: scopeStatus, spaceTakeovers: spaceTakeovers)
    }

    func deletionPreview(for review: SyncReviewModel) async -> [RepoDeletionPreviewModel] {
        await sync.deletionPreview(for: review)
    }

    func startRun(
        _ review: SyncReviewModel,
        includeDeletions: Bool,
        includeHeld: Set<SharePackageID>,
        cloneFolder: URL?,
        spaceReason: String?
    ) async throws(SyncRepositoryError) -> any SyncRunControlling {
        try await sync.startRun(
            review,
            includeDeletions: includeDeletions,
            includeHeld: includeHeld,
            cloneFolder: cloneFolder,
            spaceReason: spaceReason
        )
    }

    func clone(_ repositoryID: RepoID, into folder: URL) async throws(RepoCreationError) -> URL {
        try await cloner.clone(repositoryID, into: folder)
    }

    /// Each logged-in account's token scope status (A3), keyed by login. When gh cannot list the
    /// accounts, preflight treats every account as `.ok` and gh's own errors block the changes.
    private func scopeStatus() async -> [String: ScopeStatus] {
        let accounts: [GHAccountSummaryModel]
        do {
            accounts = try await github.accounts()
        } catch {
            AppLog.ui.error("Sync preflight could not read the gh accounts")
            return [:]
        }
        var status: [String: ScopeStatus] = [:]
        for account in accounts {
            guard let listed = account.status else { continue }
            status[listed.login] = listed.scopes
        }
        return status
    }
}

extension FeatureDependencies {
    /// The live sync service over these dependencies.
    var syncService: any SyncServicing {
        LiveSyncService(sync: sync, github: github, cloner: cloner)
    }
}
