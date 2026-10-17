import EnvTools
import Foundation
import Observation
import VaultCore
import VaultData

/// Column 3 while Overview is selected (v0.8.0, tasks/todo.md R8, R9; canvas boards 1 and 5): one
/// stage across GitHub and the stage's destinations, with the `fxvault.yml` check.
///
/// The matrix is rebuilt whenever the repository's scopes or destinations change. `fxvault.yml`
/// is read once when the Overview opens (and on Read Again), through the repository's gh account;
/// without it the matrix still works, without Missing and Extra.
@Observable
final class StageOverviewViewModel {
    let repositoryID: RepoID
    private(set) var stages: [String] = []
    var stage: String? {
        didSet {
            if stage != oldValue {
                rebuild()
            }
        }
    }
    private(set) var overview: StageOverviewModel?
    private(set) var manifestState: ManifestStateModel?
    private(set) var isReadingManifest = false
    var alert: ErrorPresentationModel?
    private(set) var notice: String?
    /// The manifest panel is open (findings and parse issues).
    var showsManifestPanel = false

    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let repository: () -> RepoModel?
    @ObservationIgnored private let tasks = TaskBag()

    init(repositoryID: RepoID, dependencies: FeatureDependencies, repository: @escaping () -> RepoModel?) {
        self.repositoryID = repositoryID
        self.dependencies = dependencies
        self.repository = repository
        observe()
        readManifest()
    }

    // MARK: - Data

    private func observe() {
        let scopes = dependencies.config.observeScopes(repositoryID: repositoryID)
        tasks.set("scopes", Task { [weak self] in
            do {
                for try await _ in scopes {
                    self?.reloadStages()
                }
            } catch {
                AppLog.ui.error("Overview scope observation ended")
            }
        })
        let destinations = dependencies.destinations.observeDestinations(repositoryID: repositoryID)
        tasks.set("destinations", Task { [weak self] in
            do {
                for try await _ in destinations {
                    self?.reloadStages()
                }
            } catch {
                AppLog.ui.error("Overview destination observation ended")
            }
        })
    }

    var manifest: ManifestModel? {
        manifestState?.manifest
    }

    /// Reads `fxvault.yml` from the default branch (names only).
    func readManifest() {
        guard !isReadingManifest else { return }
        guard dependencies.actions.isGitHubReady(), dependencies.connectivity.isOnline else {
            manifestState = .unavailable
            reloadStages()
            return
        }
        isReadingManifest = true
        let overview = dependencies.overview
        let repositoryID = repositoryID
        tasks.set("manifest", Task { [weak self] in
            let state = await overview.manifest(repositoryID: repositoryID)
            guard let self else { return }
            manifestState = state
            isReadingManifest = false
            reloadStages()
        })
    }

    private func reloadStages() {
        do {
            stages = try dependencies.overview.stages(repositoryID: repositoryID, manifest: manifest)
        } catch {
            stages = []
            alert = error.presentation
        }
        let current = stage.map(EnvironmentNameValidator.foldKey)
        if let current, stages.contains(where: { EnvironmentNameValidator.foldKey($0) == current }) {
            rebuild()
        } else {
            let production = stages.first { EnvironmentNameValidator.foldKey($0) == Self.preferredStage }
            stage = production ?? stages.first
            if stage == nil { overview = nil }
        }
    }

    private func rebuild() {
        guard let stage else {
            overview = nil
            return
        }
        do {
            overview = try dependencies.overview.overview(repositoryID: repositoryID, stage: stage, manifest: manifest)
        } catch {
            overview = nil
            alert = error.presentation
        }
    }

    private static let preferredStage = "production"

    // MARK: - Columns

    func title(of column: StageOverviewColumnModel) -> String {
        switch column {
        case .github: StageOverviewCopy.githubColumn
        case .destination(let destination): destination.provider.shortTitle
        }
    }

    /// The column's second header line: the environment, or the vault, project or Vercel
    /// environment.
    func subtitle(of column: StageOverviewColumnModel) -> String {
        switch column {
        case .github(let environment): environment?.name ?? StageOverviewCopy.repositoryLevel
        case .destination(let destination): destination.title
        }
    }

    func columnTitle(id: String) -> String {
        guard let column = overview?.columns.first(where: { $0.id == id }) else { return "" }
        if case .destination(let destination) = column { return destination.copyTargetTitle }
        return title(of: column)
    }

    var destinationCount: Int {
        overview?.columns.count { if case .destination = $0 { return true } else { return false } } ?? 0
    }

    // MARK: - Actions

    /// Opens the place of a cell: the destination, or the GitHub environment (or Repository).
    func open(row: StageOverviewRowModel, column index: Int) {
        guard let overview, overview.columns.indices.contains(index) else { return }
        switch overview.columns[index] {
        case .github(let environment):
            dependencies.actions.openPlace(.scope(
                repositoryID: repositoryID,
                scope: environment.map { .environment($0.id) } ?? .repository
            ))
        case .destination(let destination):
            dependencies.actions.openPlace(.destination(destination.id))
        }
    }

    /// Share Stage… (v0.9.0): the project share sheet with this repository and stage checked.
    func shareStage() {
        guard let stage else { return }
        dependencies.actions.present(.shareExport(ShareExportContext(selection: .repository(repositoryID), stage: stage)))
    }

    /// Add Destination for a manifest target the repository has no destination for yet.
    func addDestination(for location: ManifestLocation) {
        dependencies.actions.present(.addDestination(AddDestinationContext(
            repositoryID: repositoryID,
            suggestion: AddDestinationSuggestion(location: location, stage: stage)
        )))
    }

    /// Copies `fxvault.yml` text describing the repository now (names only, to commit).
    func copyDraftManifest() {
        do {
            let draft = try dependencies.overview.draftManifest(repositoryID: repositoryID)
            dependencies.clipboard.copyCommand(ManifestSerializer.render(draft))
            notice = StageOverviewCopy.draftCopied
        } catch {
            alert = error.presentation
        }
    }

    /// The targets `.env.example` can be generated for (the manifest's non-GitHub targets).
    var exampleTargets: [ManifestTargetModel] {
        manifest?.targets.filter { $0.provider != .githubActions } ?? []
    }

    func copyEnvExample(target: String) {
        guard let manifest else { return }
        dependencies.clipboard.copyCommand(ManifestEnvExample.render(manifest, target: target, stage: stage))
        notice = StageOverviewCopy.exampleCopied(target)
    }

    var parseIssues: [ManifestIssue] {
        if case .read(_, let result) = manifestState { return result.issues }
        return []
    }
}

/// What Add Destination starts from when it comes from the manifest check.
struct AddDestinationSuggestion: Hashable {
    let location: ManifestLocation
    let stage: String?
}
