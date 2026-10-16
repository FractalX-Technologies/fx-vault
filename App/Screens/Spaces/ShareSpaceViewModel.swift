import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// Scope menu › Share with Teammates… (v0.6.0, S1): choose paired teammates, then version 1 of
/// the scope (every item as GitHub holds it, values included) is recorded and its marker written
/// on GitHub. The teammates get it the next time this Mac reaches them.
///
/// The scope must be fully synced first (nothing pending, no secret without its value here):
/// the sheet lists what to fix instead of the teammates otherwise.
@Observable
final class ShareSpaceViewModel {
    /// One paired teammate to choose.
    struct TeammateRowModel: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
    }

    private(set) var isLoaded = false
    private(set) var readiness: SpaceReadinessModel?
    private(set) var teammates: [TeammateRowModel] = []
    var chosen: Set<String> = []
    var reason = ""
    private(set) var isSharing = false
    /// Set once the scope is shared: the sheet shows the outcome.
    private(set) var sharedSpaceID: SpaceID?
    var alert: ErrorPresentationModel?

    let context: ShareSpaceContext
    @ObservationIgnored private let dependencies: FeatureDependencies

    init(context: ShareSpaceContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
    }

    func load() {
        do {
            readiness = try dependencies.spaces.readiness(repositoryID: context.repositoryID, scope: context.scope)
            teammates = try dependencies.team.teammates().map { teammate in
                TeammateRowModel(
                    id: teammate.id,
                    name: teammate.name,
                    detail: [teammate.login, teammate.macName].filter { !$0.isEmpty && $0 != teammate.name }.joined(separator: " · ")
                )
            }
        } catch {
            alert = error.presentation
        }
        isLoaded = true
    }

    /// "Production" or "Repository", for the subtitle.
    var scopeName: String {
        guard let id = context.scope.environmentID else { return SpaceCopy.repositoryScope }
        return (try? dependencies.config.scopes(repositoryID: context.repositoryID))?
            .first { $0.environment?.id == id }?.title ?? ""
    }

    var isReady: Bool {
        readiness?.isReady == true
    }

    var canShare: Bool {
        isReady && !chosen.isEmpty && !isSharing && sharedSpaceID == nil
            && dependencies.actions.isGitHubReady() && dependencies.connectivity.isOnline
    }

    func toggle(_ id: String) {
        if chosen.contains(id) {
            chosen.remove(id)
        } else {
            chosen.insert(id)
        }
    }

    /// Records version 1, writes the marker and tells the chosen teammates.
    func share() async {
        guard canShare else { return }
        isSharing = true
        defer { isSharing = false }
        do {
            sharedSpaceID = try await dependencies.spaces.share(
                repositoryID: context.repositoryID,
                scope: context.scope,
                with: chosen.sorted(),
                me: dependencies.actions.spaceIdentity(),
                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dependencies.gitHubReachability.recordSuccess()
            dependencies.actions.spacesPublished()
        } catch {
            if case .github(let ghError) = error {
                dependencies.gitHubReachability.record(ghError)
            }
            alert = error.presentation
        }
    }

    /// Opens the shared scope's sheet in place of this one.
    func showSpace() {
        guard let sharedSpaceID else { return }
        dependencies.actions.present(.space(SpaceContext(spaceID: sharedSpaceID)))
    }
}
