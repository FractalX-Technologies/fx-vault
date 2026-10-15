import Foundation
import GitHubKit
import VaultCore

/// Reconciliation of `gh repo create` without trusting the local clock (tasks/todo.md §7.3):
/// adopt the repository when the journal records a B2 lookup that found the name free ("Could
/// not resolve to a Repository") **followed by** a create attempt, and B2 now finds the
/// repository with the expected owner and visibility. `createdAt` is never compared with the
/// journal's `started_at`.
enum RepositoryAdoption {
    /// True when the journal shows a "free" lookup and then a create attempt for the repository.
    static func journalAllowsAdoption(_ entries: [SyncJournalEntryModel]) -> Bool {
        let sorted = entries.sorted { ($0.id ?? SyncJournalEntryID(0)) < ($1.id ?? SyncJournalEntryID(0)) }
        guard let lookup = sorted.firstIndex(where: {
            $0.command == .repoView && $0.errorCode == GHError.notFound.logCode
        }) else { return false }
        return sorted[sorted.index(after: lookup)...].contains { entry in
            entry.command == .repoCreate && entry.state != .failed && entry.state != .skipped
        }
    }

    /// True when the listed repository is the one we asked for.
    static func matches(_ dto: GHRepoDTO, request: RepositoryCreateChangeModel) -> Bool {
        OwnerLoginValidator.foldKey(dto.owner.login) == OwnerLoginValidator.foldKey(request.ownerLogin)
            && dto.repoVisibility == request.visibility
    }

    /// The effect that records the adopted (or confirmed) repository.
    static func effect(repositoryID: RepoID, dto: GHRepoDTO, fallbackName: String) -> SyncStateEffectModel {
        let permission = dto.permission
        return .repositoryCreated(RepositoryCreatedEffectModel(
            repositoryID: repositoryID,
            githubID: dto.id,
            ownerLogin: dto.repoRef?.owner ?? dto.owner.login,
            name: dto.repoRef?.name ?? fallbackName,
            visibility: dto.repoVisibility,
            defaultBranch: dto.defaultBranch,
            hasAdmin: permission?.hasAdmin ?? true,
            hasPush: permission?.hasPush ?? true,
            createdAt: dto.createdAt
        ))
    }

    /// Applies a ``SyncStateEffectModel/repositoryCreated(_:)`` effect to a snapshot.
    static func apply(_ dto: GHRepoDTO, to snapshot: inout RepoSnapshotModel) {
        snapshot.repository.githubID = dto.id
        if let ref = dto.repoRef {
            snapshot.repository.ownerLogin = ref.owner
            snapshot.repository.name = ref.name
        }
        snapshot.repository.visibility = dto.repoVisibility
        snapshot.repository.defaultBranch = dto.defaultBranch
        if let permission = dto.permission {
            snapshot.repository.hasAdmin = permission.hasAdmin
            snapshot.repository.hasPush = permission.hasPush
        }
        snapshot.repository.createdAtGitHub = dto.createdAt
    }
}
