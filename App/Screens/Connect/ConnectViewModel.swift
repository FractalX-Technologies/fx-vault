import Foundation
import GitHubKit
import Observation
import VaultCore
import VaultData

/// What the first import stored, by source (board FirstImport). Secrets are names only.
struct FirstImportSummaryModel: Equatable {
    var organizationCount = 0
    var organizationSecretCount = 0
    var organizationVariableCount = 0
    var repositoryCount = 0
    var environmentCount = 0
    var repositorySecretCount = 0
    var repositoryVariableCount = 0
    /// Organizations and `owner/name` repositories whose import failed; the rest was kept.
    var failedNames: [String] = []

    var totalSecretCount: Int {
        organizationSecretCount + repositorySecretCount
    }

    var totalVariableCount: Int {
        organizationVariableCount + repositoryVariableCount
    }
}

/// The Connect phase after onboarding (1.0, boards ConnectGitHub and FirstImport). An
/// organization imports its own secrets and variables; a personal row imports each of the
/// account's repositories that is neither archived nor already in the vault.
@Observable
final class ConnectViewModel: LockObserving {
    struct Source: Identifiable, Hashable {
        enum Kind: Hashable {
            case organization(OrgAccessStatus)
            case personal(repositories: [GHRepoRef])
        }

        let login: String
        let accountLogin: String
        let kind: Kind

        var id: String {
            switch kind {
            case .organization: "org:\(OwnerLoginValidator.foldKey(login))"
            case .personal: "personal:\(OwnerLoginValidator.foldKey(login))"
            }
        }

        var isReady: Bool {
            switch kind {
            case .organization(let status): status == .ready
            case .personal(let repositories): !repositories.isEmpty
            }
        }
    }

    struct AccountSection: Identifiable, Hashable {
        let accountLogin: String
        let sources: [Source]

        var id: String {
            OwnerLoginValidator.foldKey(accountLogin)
        }
    }

    private(set) var sections: [AccountSection] = []
    var selection: Set<Source.ID> = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var isImporting = false
    /// The organization or repository being imported.
    private(set) var importingName: String?
    private(set) var summary: FirstImportSummaryModel?
    private(set) var error: ErrorPresentationModel?

    @ObservationIgnored private let app: AppViewModel

    init(app: AppViewModel) {
        self.app = app
        app.addLockObserver(self)
    }

    private var data: VaultDataComponents {
        app.container.data
    }

    var selectedSources: [Source] {
        sections.flatMap(\.sources).filter { selection.contains($0.id) }
    }

    var canContinue: Bool {
        !isLoading && !isImporting && !selectedSources.isEmpty
    }

    // MARK: - Loading

    /// Reads each account's organizations and personal repositories, then checks the ready ones.
    func load() async {
        guard !isLoading, app.phase == .unlocked else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        error = nil
        // Right after onboarding the launch probe may still be locating gh; reading accounts
        // before it finishes would report "gh not found".
        await app.ghProbeTask?.value
        let accounts: [GHAccountSummaryModel]
        do {
            accounts = try await data.github.accounts()
        } catch {
            self.error = error.presentation
            return
        }
        var loaded: [AccountSection] = []
        for account in accounts where account.status?.state == .ok {
            let login = account.account.login
            var sources: [Source] = []
            // A failing read leaves its rows out; Settings › Accounts explains the account.
            if let organizations = try? await data.github.organizationAccess(accountLogin: login) {
                sources += organizations.map { Source(login: $0.login, accountLogin: login, kind: .organization($0.status)) }
            }
            if let personal = try? await personalRepositories(accountLogin: login) {
                sources.append(Source(login: login, accountLogin: login, kind: .personal(repositories: personal)))
            }
            loaded.append(AccountSection(accountLogin: login, sources: sources))
        }
        sections = Self.deduplicatingOrganizations(loaded)
        selection = Set(sections.flatMap(\.sources).filter(\.isReady).map(\.id))
    }

    private func personalRepositories(accountLogin: String) async throws -> [GHRepoRef] {
        let catalog = try await data.catalog.catalog(accountLogin: accountLogin)
        let key = OwnerLoginValidator.foldKey(accountLogin)
        guard let owner = catalog.owners.first(where: { $0.ownerType == .user && $0.id == key }), owner.failure == nil else {
            throw RepoCatalogError.repositoryNotFound
        }
        return owner.repositories.filter { !$0.isArchived && !$0.isImported }.map(\.ref)
    }

    /// An organization two accounts reach is listed once: under the first account that can read
    /// its secrets, else under the first account.
    static func deduplicatingOrganizations(_ sections: [AccountSection]) -> [AccountSection] {
        var keeper: [Source.ID: (section: String, isReady: Bool)] = [:]
        for section in sections {
            for source in section.sources {
                guard case .organization = source.kind else { continue }
                let kept = keeper[source.id]
                if kept == nil || (source.isReady && kept?.isReady == false) {
                    keeper[source.id] = (section.id, source.isReady)
                }
            }
        }
        return sections.map { section in
            AccountSection(
                accountLogin: section.accountLogin,
                sources: section.sources.filter { source in
                    guard case .organization = source.kind else { return true }
                    return keeper[source.id]?.section == section.id
                }
            )
        }
    }

    // MARK: - Import

    func toggle(_ source: Source) {
        guard source.isReady, !isImporting else { return }
        if selection.contains(source.id) {
            selection.remove(source.id)
        } else {
            selection.insert(source.id)
        }
    }

    /// Imports every checked source in order; a failure is named in the summary and the rest
    /// goes on.
    func importSelected() async {
        guard canContinue else { return }
        isImporting = true
        error = nil
        defer {
            isImporting = false
            importingName = nil
        }
        var result = FirstImportSummaryModel()
        for source in selectedSources {
            guard app.phase == .unlocked else { return }
            switch source.kind {
            case .organization:
                importingName = source.login
                do {
                    let imported = try await data.organizations.importOrganization(login: source.login, accountLogin: source.accountLogin)
                    result.organizationCount += 1
                    result.organizationSecretCount += imported.organization.secretCount
                    result.organizationVariableCount += imported.organization.variableCount
                } catch {
                    result.failedNames.append(source.login)
                }
            case .personal(let repositories):
                for ref in repositories {
                    guard app.phase == .unlocked else { return }
                    let name = "\(ref.owner)/\(ref.name)"
                    importingName = name
                    do {
                        let imported = try await data.catalog.importRepository(ref, accountLogin: source.accountLogin)
                        result.repositoryCount += 1
                        result.environmentCount += imported.environmentCount
                        result.repositorySecretCount += imported.secretCount
                        result.repositoryVariableCount += imported.variableCount
                    } catch {
                        result.failedNames.append(name)
                    }
                }
            }
        }
        summary = result
    }

    /// **Not Now** on Connect, or **Continue** on the summary.
    func finish() {
        app.finishFirstConnect()
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        sections = []
        selection = []
        summary = nil
        error = nil
    }
}
