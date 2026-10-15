import Foundation
import SyncEngine
import VaultCore
import VaultData

/// What ``DriftReviewViewModel`` needs from VaultData's `DriftRepository`. The live
/// implementation is ``LiveDriftService``; view-model tests use a fake.
nonisolated protocol DriftServicing: Sendable {
    /// The last report of the repository, without checking GitHub.
    func cachedReport(for repositoryID: RepoID) async -> DriftReportModel?
    /// A full re-list and drift check now (§7.7 Refresh).
    func refresh(_ repositoryID: RepoID) async throws(DriftRepositoryError) -> DriftReportModel
    /// Applies one resolution after re-reading the finding's scope (`.stale` when GitHub
    /// changed again).
    func resolve(
        _ drift: DriftModel,
        option: DriftResolutionOption
    ) async throws(DriftRepositoryError) -> DriftResolutionResultModel
}

/// ``DriftServicing`` over the app's single `DriftRepository`.
nonisolated struct LiveDriftService: DriftServicing {
    let drift: DriftRepository

    func cachedReport(for repositoryID: RepoID) async -> DriftReportModel? {
        await drift.report(for: repositoryID)
    }

    func refresh(_ repositoryID: RepoID) async throws(DriftRepositoryError) -> DriftReportModel {
        try await drift.refresh(repositoryID)
    }

    func resolve(
        _ drift: DriftModel,
        option: DriftResolutionOption
    ) async throws(DriftRepositoryError) -> DriftResolutionResultModel {
        try await self.drift.resolve(drift, option: option)
    }
}

extension FeatureDependencies {
    /// The live drift service over these dependencies.
    var driftService: any DriftServicing {
        LiveDriftService(drift: drift)
    }
}
