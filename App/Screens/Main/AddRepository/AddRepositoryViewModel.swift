import Foundation
import Observation
import VaultCore
import VaultData

/// "Add repository by name…" (§10 Column 1): checks `owner/name` with B2 through the account,
/// for collaborator access gh cannot list. The found repository joins the sidebar; Import keeps
/// it.
@Observable
final class AddRepositoryViewModel {
    let accountLogin: String
    var fullName = ""
    private(set) var isChecking = false
    private(set) var error: ErrorPresentationModel?

    @ObservationIgnored private let catalog: RepoCatalogRepository
    @ObservationIgnored private let connectivity: ConnectivityMonitor
    @ObservationIgnored private let gitHubReachability: GitHubReachability
    @ObservationIgnored private let onAdded: (CatalogRepoModel) -> Void

    init(
        context: AddRepositoryContext,
        catalog: RepoCatalogRepository,
        connectivity: ConnectivityMonitor,
        gitHubReachability: GitHubReachability,
        onAdded: @escaping (CatalogRepoModel) -> Void
    ) {
        accountLogin = context.accountLogin
        self.catalog = catalog
        self.connectivity = connectivity
        self.gitHubReachability = gitHubReachability
        self.onAdded = onAdded
    }

    /// False while the Mac has no internet connection (the look-up calls GitHub).
    var isOnline: Bool {
        connectivity.isOnline
    }

    private var trimmedName: String {
        fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `owner/name` with exactly one slash.
    var canAdd: Bool {
        let parts = trimmedName.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && !isChecking && isOnline
    }

    /// Looks the repository up; returns true when it was added.
    func add() async -> Bool {
        guard canAdd else { return false }
        isChecking = true
        error = nil
        defer { isChecking = false }
        do {
            let repo = try await catalog.lookUpRepository(fullName: trimmedName, accountLogin: accountLogin)
            gitHubReachability.recordSuccess()
            onAdded(repo)
            return true
        } catch .github(.notFound) {
            gitHubReachability.recordSuccess()
            error = ErrorPresentationModel(
                title: String(localized: "main.addRepo.notFound.title", defaultValue: "Repository not found"),
                message: String(
                    localized: "main.addRepo.notFound.message",
                    defaultValue: "\(accountLogin) cannot see \(trimmedName). Check the name and that this account has access."
                )
            )
        } catch {
            gitHubReachability.record(error)
            self.error = error.presentation
        }
        return false
    }
}
