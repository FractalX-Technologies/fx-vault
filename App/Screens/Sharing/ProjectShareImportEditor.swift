import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// The user's choices on a project share's preview (v0.9.0, P7): per repository the GitHub
/// scopes (through a ``ShareImportPlanEditor`` whose choices are copied into the bundle plan),
/// the destinations' item actions, the folders and the replay confirmation.
///
/// Holds only the plan (names, chips, actions); values never reach the UI.
@Observable
final class ProjectShareImportEditor {
    /// One line of the repository list (✓ ⇣ ✕).
    struct RepositoryRowModel: Identifiable, Equatable {
        enum Mark: Equatable {
            case inVault
            case willImport
            case skipped
        }

        let id: String
        let fullName: String
        let mark: Mark
        let detail: String
        let counts: ShareItemCountModel
        let destinationCount: Int
    }

    private(set) var plan: ShareBundlePlanModel
    /// "Import anyway" for the replay warnings.
    var confirmsReplay = false
    /// The repository whose preview is shown under the list.
    var selectedRepositoryID: String?
    let sender: ShareFileSenderModel
    let createdAt: Date
    let expiresAt: Date

    @ObservationIgnored private var editors: [String: ShareImportPlanEditor] = [:]
    /// Every choice in order, so a new plan of the same file (after the ⇣ repositories were
    /// imported, or after `.planOutdated`) starts with them.
    @ObservationIgnored private(set) var choices: [Choice] = []

    /// One recorded choice.
    enum Choice: Equatable {
        case github(ShareImportPlanEditor.Change, repositoryID: String)
        case destinationItem(ShareItemAction, item: ShareEntryID)
        case folder(ShareFolderPlanAction, folder: ShareEntryID)
    }

    /// - Parameter previous: the editor of an earlier plan of the same file, whose choices,
    ///   replay confirmation and selected repository carry over where they still apply.
    init(draft: ShareBundleDraftModel, replaying previous: ProjectShareImportEditor? = nil) {
        plan = draft.plan
        sender = draft.sender
        createdAt = draft.manifest.createdAt
        expiresAt = draft.manifest.expiresAt
        selectedRepositoryID = draft.plan.repositories.first { $0.status.isImportedNow }?.id
            ?? draft.plan.repositories.first?.id
        guard let previous else { return }
        confirmsReplay = previous.confirmsReplay
        if let selected = previous.selectedRepositoryID, plan.repositories.contains(where: { $0.id == selected }) {
            selectedRepositoryID = selected
        }
        for choice in previous.choices {
            replay(choice)
        }
    }

    private func replay(_ choice: Choice) {
        switch choice {
        case .github(let change, let repositoryID):
            apply(change, inRepository: repositoryID)
            editors[repositoryID] = nil
        case .destinationItem(let action, let item):
            select(action, forDestinationItem: item)
        case .folder(let action, let folder):
            guard let plan = plan.folders.first(where: { $0.id == folder }) else { return }
            setFolderAction(action, for: plan)
        }
    }

    // MARK: - Repositories

    var repositoryRows: [RepositoryRowModel] {
        plan.repositories.map { repository in
            let summary = repository.summary
            return RepositoryRowModel(
                id: repository.id,
                fullName: repository.fullName,
                mark: Self.mark(of: repository.status),
                detail: Self.detail(of: repository.status),
                counts: Self.counts(of: summary),
                destinationCount: summary.destinations.count
            )
        }
    }

    /// Secrets and variables of a repository's GitHub scopes and destinations.
    static func counts(of summary: ShareBundleRepositorySummaryModel) -> ShareItemCountModel {
        let scopes = [summary.content.repositoryLevel] + summary.content.environments.map(\.counts) + summary.destinations.map(\.counts)
        return ShareItemCountModel(
            secrets: scopes.map(\.secrets).reduce(0, +),
            variables: scopes.map(\.variables).reduce(0, +)
        )
    }

    static func mark(of status: ShareBundleRepositoryStatus) -> RepositoryRowModel.Mark {
        switch status {
        case .inVault: .inVault
        case .willImportFromGitHub: .willImport
        case .noAccess, .blocked: .skipped
        }
    }

    static func detail(of status: ShareBundleRepositoryStatus) -> String {
        switch status {
        case .inVault: ProjectShareCopy.inVault
        case .willImportFromGitHub(let account): ProjectShareCopy.willImport(account)
        case .noAccess(let reason): ProjectShareCopy.skipped(reason)
        case .blocked(let reason): reason.localizedMessage
        }
    }

    var selectedRepository: ShareBundleRepositoryPlanModel? {
        plan.repositories.first { $0.id == selectedRepositoryID }
    }

    /// The GitHub preview of a repository imported now; its choices go into ``plan``.
    func githubEditor(for repository: ShareBundleRepositoryPlanModel) -> ShareImportPlanEditor? {
        guard repository.status.isImportedNow, let githubPlan = repository.githubPlan else { return nil }
        if let editor = editors[repository.id] {
            return editor
        }
        let editor = ShareImportPlanEditor(plan: githubPlan, repositoryFullName: repository.fullName)
        let repositoryID = repository.id
        editor.onChange = { [weak self] change in
            self?.apply(change, inRepository: repositoryID)
        }
        editors[repository.id] = editor
        return editor
    }

    private func apply(_ change: ShareImportPlanEditor.Change, inRepository repositoryID: String) {
        do {
            switch change {
            case .select(let action, let item):
                try plan.select(action, forItem: item)
            case .policy(let decision, let environment, let wideningConfirmed):
                try plan.setPolicyDecision(
                    decision,
                    forEnvironment: environment,
                    inRepository: repositoryID,
                    wideningConfirmed: wideningConfirmed
                )
            }
            choices.append(.github(change, repositoryID: repositoryID))
        } catch {
            // A choice that no longer applies to this plan (replayed after a new plan).
        }
    }

    /// The repositories that will be imported from GitHub first.
    var needsRepositoryImport: Bool {
        !plan.repositoriesToImport.isEmpty
    }

    // MARK: - Destinations and folders

    func select(_ action: ShareItemAction, forDestinationItem id: ShareEntryID) {
        do {
            try plan.select(action, forItem: id)
            choices.append(.destinationItem(action, item: id))
        } catch {
            // The picker offers only allowed actions.
        }
    }

    func setFolderAction(_ action: ShareFolderPlanAction, for folder: ShareBundleFolderPlanModel) {
        do {
            try plan.setFolderAction(action, forFolder: folder.id)
            choices.append(.folder(action, folder: folder.id))
        } catch {
            // Only the actions ``folderActions(for:)`` lists are offered.
        }
    }

    /// The choices a folder offers: a new folder, a merge into the one with the same name (keep
    /// or replace), or skip.
    func folderActions(for folder: ShareBundleFolderPlanModel) -> [ShareFolderPlanAction] {
        var actions: [ShareFolderPlanAction] = [.createNew(name: folder.name)]
        if let existing = folder.existingFolderID {
            actions.append(.mergeInto(existing, conflicts: .keepMine))
            actions.append(.mergeInto(existing, conflicts: .replace))
        }
        actions.append(.skip)
        return actions
    }

    static func title(of action: ShareFolderPlanAction) -> String {
        switch action {
        case .createNew: ProjectShareCopy.newFolder
        case .mergeInto(_, conflicts: .keepMine): ProjectShareCopy.mergeFolderKeep
        case .mergeInto(_, conflicts: .replace): ProjectShareCopy.mergeFolderReplace
        case .skip: ProjectShareCopy.skipFolder
        }
    }

    // MARK: - Apply

    var canApply: Bool {
        let importsSomething = !plan.importedRepositories.isEmpty || needsRepositoryImport
            || plan.folders.contains { $0.action != .skip }
        let widening = editors.values.contains { $0.pendingWideningEnvironment != nil }
        return importsSomething && (!plan.requiresReplayConfirmation || confirmsReplay) && !widening
    }

    var changedCount: Int {
        plan.changedItemCount
    }
}
