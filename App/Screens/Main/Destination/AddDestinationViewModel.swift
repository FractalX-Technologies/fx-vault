import DestinationKit
import EnvTools
import Foundation
import Observation
import VaultCore
import VaultData

/// "+ Add Destination" (v0.8.0, tasks/todo.md R7): the provider, the stage, the target (a Key
/// Vault name and optional tenant; a Supabase project or a Vercel project, team and environment
/// from the connection's lists) and, for Supabase and Vercel, a connection (an existing one or a
/// new token, checked before it is saved). Adding imports what the destination already holds.
///
/// A new token lives only in ``newToken`` while the sheet is open; it is cleared after the save
/// and on lock, and never logged.
@Observable
final class AddDestinationViewModel: LockObserving {
    enum Phase: Equatable {
        case form
        case working
        /// Added; the import's outcome (or why it could not run).
        case done(DestinationAddedModel)
    }

    enum ConnectionChoice: Hashable {
        case existing(ConnectionID)
        case newToken
    }

    let context: AddDestinationContext
    var provider: DestinationProvider = .azureKeyVault {
        didSet {
            guard provider != oldValue else { return }
            resetTarget()
            chooseDefaultConnection()
        }
    }
    var stage: String = ""
    private(set) var stageSuggestions: [String] = []

    var vaultName = ""
    var tenantID = ""

    private(set) var connections: [ConnectionModel] = []
    var connectionChoice: ConnectionChoice = .newToken {
        didSet {
            if connectionChoice != oldValue {
                resetLists()
            }
        }
    }
    var newTokenLabel = ""
    var newToken = ""

    private(set) var supabaseProjects: [SupabaseProjectModel] = []
    var projectRef = ""

    private(set) var vercelUser: VercelUserModel?
    private(set) var vercelTeams: [VercelTeamModel] = []
    /// nil: the personal account.
    var vercelTeamID: String? {
        didSet {
            if vercelTeamID != oldValue {
                vercelProjects = []
                vercelProjectID = nil
            }
        }
    }
    private(set) var vercelProjects: [VercelProjectModel] = []
    var vercelProjectID: String?
    var vercelEnvironment: VercelEnvironment = .production

    private(set) var isLoadingLists = false
    private(set) var listError: String?
    private(set) var phase: Phase = .form
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let tasks = TaskBag()
    /// A Vercel project the suggestion names, chosen once the projects arrive.
    @ObservationIgnored private var suggestedVercelProject: String?

    init(context: AddDestinationContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
        dependencies.actions.addLockObserver(self)
        loadStages()
        loadConnections()
        apply(context.suggestion)
    }

    // MARK: - Loading

    private func loadStages() {
        stageSuggestions = (try? dependencies.overview.stages(repositoryID: context.repositoryID, manifest: nil)) ?? []
        if stage.isEmpty {
            stage = stageSuggestions.first { EnvironmentNameValidator.foldKey($0) == Self.defaultStage } ?? stageSuggestions.first ?? Self.defaultStage
        }
    }

    private func loadConnections() {
        connections = (try? dependencies.destinations.connections()) ?? []
        chooseDefaultConnection()
    }

    private var providerConnections: [ConnectionModel] {
        connections.filter { $0.provider == provider }
    }

    /// The connections of the chosen provider.
    var availableConnections: [ConnectionModel] {
        providerConnections
    }

    private func chooseDefaultConnection() {
        guard provider.usesConnection else { return }
        connectionChoice = providerConnections.first.map { .existing($0.id) } ?? .newToken
        if case .existing = connectionChoice {
            loadLists()
        }
    }

    private func apply(_ suggestion: AddDestinationSuggestion?) {
        guard let suggestion else { return }
        if let stage = suggestion.stage { self.stage = stage }
        switch suggestion.location {
        case .keyVault(let vaultName):
            provider = .azureKeyVault
            self.vaultName = vaultName
        case .supabase(let projectRef):
            provider = .supabase
            self.projectRef = projectRef
        case .vercel(let project, let team, let environment):
            provider = .vercel
            vercelTeamID = team
            vercelEnvironment = VercelEnvironment(rawValue: environment.rawValue) ?? .production
            suggestedVercelProject = project
        case .githubEnvironment:
            break
        }
    }

    private func resetTarget() {
        vaultName = ""
        tenantID = ""
        projectRef = ""
        vercelProjectID = nil
        resetLists()
    }

    private func resetLists() {
        supabaseProjects = []
        vercelUser = nil
        vercelTeams = []
        vercelProjects = []
        listError = nil
    }

    /// Loads the projects (Supabase) or the account, teams and projects (Vercel) of the chosen
    /// connection.
    func loadLists() {
        guard provider.usesConnection, case .existing(let connectionID) = connectionChoice else { return }
        guard dependencies.connectivity.isOnline else {
            listError = ConnectivityCopy.offlineHelp
            return
        }
        isLoadingLists = true
        listError = nil
        let access = dependencies.destinationAccess
        let provider = provider
        let teamID = vercelTeamID
        tasks.set("lists", Task { [weak self] in
            do throws(DestinationSyncError) {
                switch provider {
                case .supabase:
                    let projects = try await access.supabaseProjects(connectionID: connectionID)
                    self?.supabaseProjects = projects
                    if self?.projectRef.isEmpty == true, projects.count == 1 { self?.projectRef = projects[0].ref }
                case .vercel:
                    let scopes = try await access.vercelScopes(connectionID: connectionID)
                    self?.vercelUser = scopes.user
                    self?.vercelTeams = scopes.teams
                    let projects = try await access.vercelProjects(connectionID: connectionID, teamID: teamID)
                    self?.applyVercelProjects(projects)
                case .azureKeyVault:
                    break
                }
            } catch {
                self?.listError = error.presentation(provider: provider).message
            }
            self?.isLoadingLists = false
        })
    }

    /// Loads the projects of the chosen Vercel team.
    func loadVercelProjects() {
        guard provider == .vercel, case .existing(let connectionID) = connectionChoice else { return }
        isLoadingLists = true
        let access = dependencies.destinationAccess
        let teamID = vercelTeamID
        tasks.set("projects", Task { [weak self] in
            do throws(DestinationSyncError) {
                self?.applyVercelProjects(try await access.vercelProjects(connectionID: connectionID, teamID: teamID))
            } catch {
                self?.listError = error.presentation(provider: .vercel).message
            }
            self?.isLoadingLists = false
        })
    }

    private func applyVercelProjects(_ projects: [VercelProjectModel]) {
        vercelProjects = projects
        if let suggested = suggestedVercelProject,
           let match = projects.first(where: { $0.name == suggested || $0.id == suggested }) {
            vercelProjectID = match.id
            suggestedVercelProject = nil
        } else if vercelProjectID == nil, projects.count == 1 {
            vercelProjectID = projects[0].id
        }
    }

    // MARK: - Form

    var title: String {
        AddDestinationCopy.title
    }

    /// The target the fields describe, or nil while something is missing.
    var target: DestinationTargetModel? {
        switch provider {
        case .azureKeyVault:
            let name = vaultName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return .azureKeyVault(vaultName: name, tenantID: tenantID.isEmpty ? nil : tenantID)
        case .supabase:
            let ref = projectRef.trimmingCharacters(in: .whitespaces)
            return ref.isEmpty ? nil : .supabase(projectRef: ref)
        case .vercel:
            guard let vercelProjectID, let project = vercelProjects.first(where: { $0.id == vercelProjectID }) else { return nil }
            return .vercel(projectID: project.id, projectName: project.name, teamID: vercelTeamID, environment: vercelEnvironment)
        }
    }

    /// Why the target cannot be added yet (shown under the fields), or nil.
    var targetProblem: String? {
        guard let target else { return nil }
        do {
            _ = try DestinationRules.validate(target)
            return nil
        } catch {
            return error.localizedMessage
        }
    }

    var stageProblem: String? {
        let trimmed = stage.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return EnvironmentNameValidator.violation(in: trimmed)?.localizedMessage
    }

    private var hasConnection: Bool {
        guard provider.usesConnection else { return true }
        switch connectionChoice {
        case .existing: return true
        case .newToken: return false
        }
    }

    var canAdd: Bool {
        phase == .form && target != nil && targetProblem == nil && stageProblem == nil && hasConnection && dependencies.connectivity.isOnline
    }

    /// With a new token, the Vercel and Supabase lists need the token saved first.
    var needsTokenBeforeLists: Bool {
        provider.usesConnection && connectionChoice == .newToken
    }

    var canSaveToken: Bool {
        needsTokenBeforeLists && !newToken.isEmpty && !isLoadingLists && dependencies.connectivity.isOnline
    }

    /// Checks and saves the new token, then loads the lists.
    func saveToken() {
        guard canSaveToken else { return }
        let provider = provider
        let label = newTokenLabel.trimmingCharacters(in: .whitespaces).isEmpty ? provider.title : newTokenLabel
        let token = SecretBytes(utf8: newToken)
        newToken = ""
        isLoadingLists = true
        let access = dependencies.destinationAccess
        let destinations = dependencies.destinations
        tasks.set("token", Task { [weak self] in
            defer { token.wipe() }
            do throws(DestinationError) {
                let hint = try await access.check(token, provider: provider)
                do {
                    let id = try destinations.addConnection(provider: provider, label: label, token: token, accountHint: hint)
                    self?.connections = (try? destinations.connections()) ?? []
                    self?.connectionChoice = .existing(id)
                    self?.isLoadingLists = false
                    self?.loadLists()
                } catch {
                    self?.alert = error.presentation
                    self?.isLoadingLists = false
                }
            } catch {
                self?.listError = error.localizedMessage(provider: provider)
                self?.isLoadingLists = false
            }
        })
    }

    // MARK: - Add

    /// Adds the destination, then imports what it already holds.
    func add() {
        guard canAdd, let target else { return }
        let connectionID: ConnectionID?
        switch (provider.usesConnection, connectionChoice) {
        case (false, _): connectionID = nil
        case (true, .existing(let id)): connectionID = id
        case (true, .newToken):
            return
        }
        let trimmedStage = stage.trimmingCharacters(in: .whitespaces)
        let id: DestinationID
        do {
            id = try dependencies.destinations.createDestination(
                repositoryID: context.repositoryID,
                target: target,
                stage: trimmedStage.isEmpty ? nil : trimmedStage,
                connectionID: connectionID
            )
        } catch {
            alert = error.presentation
            return
        }
        phase = .working
        let sync = dependencies.destinationSync
        let provider = provider
        tasks.set("import", Task { [weak self] in
            let outcome: DestinationAddedModel
            do throws(DestinationSyncError) {
                outcome = DestinationAddedModel(destinationID: id, result: try await sync.importRemote(destinationID: id), importError: nil)
            } catch {
                outcome = DestinationAddedModel(destinationID: id, result: nil, importError: error.presentation(provider: provider).message)
            }
            self?.phase = .done(outcome)
        })
    }

    /// Done: shows the new destination.
    func openDestination() {
        guard case .done(let added) = phase else { return }
        dependencies.actions.openPlace(.destination(added.destinationID))
    }

    private static let defaultStage = "production"

    // MARK: - LockObserving

    func vaultDidLock() {
        newToken = ""
        tasks.cancelAll()
    }
}

/// The outcome of Add Destination: the import's result, or why it could not run (the
/// destination stays; Refresh imports later).
struct DestinationAddedModel: Equatable {
    let destinationID: DestinationID
    let result: DestinationImportResultModel?
    let importError: String?
}
