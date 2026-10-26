import Foundation
import GitHubKit
import os
import SyncEngine
import VaultCore
import VaultData
@testable import FXVault

/// A scripted ``DriftServicing`` that records refreshes and resolutions.
final class FakeDriftService: DriftServicing {
    struct Resolution: Equatable {
        let driftID: String
        let option: DriftResolutionOption
    }

    private struct State {
        var cached: DriftReportModel?
        var refreshResult: Result<DriftReportModel, DriftRepositoryError>
        var resolveError: DriftRepositoryError?
        var refreshCount = 0
        var resolutions: [Resolution] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(cached: DriftReportModel?, refresh: Result<DriftReportModel, DriftRepositoryError>) {
        state = OSAllocatedUnfairLock(initialState: State(cached: cached, refreshResult: refresh))
    }

    var refreshCount: Int {
        state.withLock { $0.refreshCount }
    }

    var resolutions: [Resolution] {
        state.withLock { $0.resolutions }
    }

    func failResolutions(with error: DriftRepositoryError?) {
        state.withLock { $0.resolveError = error }
    }

    func cachedReport(for repositoryID: RepoID) async -> DriftReportModel? {
        state.withLock { $0.cached }
    }

    func refresh(_ repositoryID: RepoID) async throws(DriftRepositoryError) -> DriftReportModel {
        let result = state.withLock { state in
            state.refreshCount += 1
            return state.refreshResult
        }
        return try result.get()
    }

    func resolve(
        _ drift: DriftModel,
        option: DriftResolutionOption
    ) async throws(DriftRepositoryError) -> DriftResolutionResultModel {
        let error = state.withLock { state in
            state.resolutions.append(Resolution(driftID: drift.id, option: option))
            return state.resolveError
        }
        if let error { throw error }
        return DriftResolutionResultModel(driftID: drift.id, option: option, followUp: drift.resolution(option).followUp)
    }
}

/// Synthetic drift findings (lessons.md: no real identifiers).
enum DriftFixtures {
    static let repositoryID = RepoID()
    static let environmentID = EnvironmentID()

    static func item(
        _ kind: DriftKind,
        _ configKind: ConfigKind,
        _ name: String,
        environment: String? = nil,
        itemID: ConfigItemID? = ConfigItemID(),
        updatedAt: Date? = nil,
        isConflict: Bool = false,
        keepLocalUnavailable: DriftUnavailableReason? = nil,
        acceptEffects: [DriftEffectModel] = []
    ) -> DriftModel {
        let scope = environment.map(RemoteScopeKeyModel.environment(named:)) ?? .repository
        let followUp: DriftFollowUpModel? = if kind == .secretModified, let itemID {
            .promptFillValue(itemID)
        } else {
            nil
        }
        let keepLocal = keepLocalUnavailable.map { DriftResolutionModel.unavailable(.keepLocal, $0) }
            ?? DriftResolutionModel(option: .keepLocal, effects: [])
        return DriftModel(
            repositoryID: repositoryID,
            kind: kind,
            subject: .item(DriftItemSubjectModel(
                key: RemoteItemKeyModel(scope: scope, kind: configKind, name: name),
                kind: configKind,
                name: name,
                environmentName: environment,
                environmentID: environment == nil ? nil : environmentID,
                itemID: itemID
            )),
            isConflict: isConflict,
            remoteUpdatedAt: updatedAt,
            keepLocal: keepLocal,
            acceptGitHub: DriftResolutionModel(option: .acceptGitHub, effects: acceptEffects, followUp: followUp)
        )
    }

    static func environment(_ kind: DriftKind, _ name: String, itemNames: [String] = []) -> DriftModel {
        DriftModel(
            repositoryID: repositoryID,
            kind: kind,
            subject: .environment(DriftEnvironmentSubjectModel(
                key: .environment(named: name),
                name: name,
                environmentID: kind == .environmentAdded ? nil : environmentID,
                githubID: kind == .environmentDeleted ? nil : 42,
                remotePolicy: kind == .environmentDeleted ? nil : .all,
                remoteItemNames: itemNames
            )),
            isConflict: false,
            remoteUpdatedAt: nil,
            keepLocal: DriftResolutionModel(option: .keepLocal, effects: []),
            acceptGitHub: DriftResolutionModel(option: .acceptGitHub, effects: [])
        )
    }

    static func report(_ drifts: [DriftModel], checkedAt: Date = Date(timeIntervalSince1970: 0)) -> DriftReportModel {
        DriftReportModel(repositoryID: repositoryID, checkedAt: checkedAt, drifts: drifts)
    }

    /// Oct 12 of the given year at noon UTC.
    static func october12(year: Int) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = 10
        components.day = 12
        components.hour = 12
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
