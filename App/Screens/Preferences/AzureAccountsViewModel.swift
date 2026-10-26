import DestinationKit
import Foundation
import Observation
import VaultCore
import VaultData

/// One Azure tenant in Settings › Accounts (1.0 S1b; board Settings-Accounts), built from the
/// Key Vaults of their own and the tenants `az account list` signs in to. Never carries the
/// signed-in user: FX Vault doesn't keep it.
struct AzureTenantRowModel: Identifiable, Hashable {
    enum SignIn: Hashable {
        case signedIn
        case notSignedIn
        /// `az` could not tell (not installed, untrusted, failed).
        case unknown
    }

    /// Lowercased; nil for vaults saved without one while no default tenant is known.
    let tenantID: String?
    /// `tenantDisplayName` from `az`; nil while the tenant is not signed in.
    let name: String?
    /// Saved vaults by subscription, in name order.
    let subscriptions: [SubscriptionVaults]
    /// Saved vaults whose subscription FX Vault doesn't know yet.
    let otherVaultCount: Int
    let signIn: SignIn

    struct SubscriptionVaults: Hashable {
        let id: UUID
        let name: String
        let vaultCount: Int
    }

    var id: String {
        tenantID ?? ""
    }

    var title: String {
        name ?? tenantID ?? AzureAccountsCopy.defaultTenant
    }

    /// "Example Production · 2 vaults, Example Staging · 1 vault", or "No vaults in FX Vault";
    /// "Not signed in · …" first when it is not.
    var subline: String {
        var parts = subscriptions.map { AzureAccountsCopy.subscriptionVaults($0.name, count: $0.vaultCount) }
        if otherVaultCount > 0 {
            parts.append(parts.isEmpty ? AzureAccountsCopy.vaults(otherVaultCount) : AzureAccountsCopy.otherVaults(otherVaultCount))
        }
        let summary = parts.isEmpty ? AzureAccountsCopy.noVaults : parts.joined(separator: ", ")
        return signIn == .notSignedIn ? AzureAccountsCopy.notSignedIn(summary) : summary
    }

    var loginCommand: String {
        AzureAccountsCopy.loginCommand(tenantID: tenantID)
    }

    /// One row per tenant: the saved vaults' tenants (a vault saved without one counts in `az`'s
    /// default tenant) and every tenant `listed` signs in to. Signed-in tenants first, then by
    /// title. `listed` is empty unless `requirement` is `.ready`.
    static func rows(
        vaults: [DestinationModel],
        listed: [AzureSubscriptionModel],
        requirement: ConnectAzureModel.Requirement?
    ) -> [AzureTenantRowModel] {
        let defaultTenant = (listed.first(where: \.isDefault) ?? listed.first)?.tenantID
        var vaultsByTenant: [String?: [DestinationModel]] = [:]
        var order: [String?] = []
        for vault in vaults {
            guard case .azureKeyVault(_, let tenantID) = vault.target else { continue }
            let tenant = tenantID?.lowercased() ?? defaultTenant
            vaultsByTenant[tenant, default: []].append(vault)
            if !order.contains(tenant) { order.append(tenant) }
        }
        for subscription in listed where !order.contains(subscription.tenantID) {
            order.append(subscription.tenantID)
        }
        let signedIn = Set(listed.map(\.tenantID))
        let rows = order.map { tenant in
            let saved = vaultsByTenant[tenant] ?? []
            return AzureTenantRowModel(
                tenantID: tenant,
                name: listed.first { $0.tenantID == tenant && $0.tenantName != nil }?.tenantName,
                subscriptions: subscriptionVaults(saved),
                otherVaultCount: saved.count(where: { $0.subscription == nil }),
                signIn: signIn(tenant: tenant, signedIn: signedIn, requirement: requirement)
            )
        }
        return rows.sorted { lhs, rhs in
            if (lhs.signIn == .signedIn) != (rhs.signIn == .signedIn) { return lhs.signIn == .signedIn }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// By subscription id: two vaults may have saved one subscription under different names,
    /// and the last one wins, as in the sidebar (``SidebarAzureModel``).
    private static func subscriptionVaults(_ saved: [DestinationModel]) -> [SubscriptionVaults] {
        Dictionary(grouping: saved.compactMap(\.subscription), by: \.id)
            .map { id, subscriptions in
                SubscriptionVaults(id: id, name: subscriptions.last?.name ?? "", vaultCount: subscriptions.count)
            }
            .sorted { lhs, rhs in
                let byName = lhs.name.localizedStandardCompare(rhs.name)
                return byName == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : byName == .orderedAscending
            }
    }

    private static func signIn(tenant: String?, signedIn: Set<String>, requirement: ConnectAzureModel.Requirement?) -> SignIn {
        switch requirement {
        case .ready: tenant.map(signedIn.contains) == true ? .signedIn : .notSignedIn
        case .notSignedIn: .notSignedIn
        case .notInstalled, .untrusted, .failed, nil: .unknown
        }
    }
}

/// Settings › Accounts › Azure (1.0 S1b; board Settings-Accounts): the tenant rows, Choose
/// Vaults… over Connect Azure's list, and the `az` logins to copy. Reads `az account list`
/// only; the logins are the user's to run in Terminal. ``AccountsSettingsViewModel`` owns it
/// and resets it on lock.
@Observable
final class AzureAccountsViewModel {
    private(set) var tenants: [AzureTenantRowModel] = []
    private(set) var requirement: ConnectAzureModel.Requirement?
    private(set) var isLoading = false
    private(set) var copiedCommand: String?
    /// Choose Vaults…: Connect Azure's list for one tenant, shown as a sheet while set.
    private(set) var chooser: ConnectAzureModel?
    private(set) var isImporting = false
    /// The vault Add Vaults is reading.
    private(set) var importingName: String?
    /// The last Add Vaults, shown under the group.
    private(set) var importResult: ConnectAzureModel.ImportResult?

    @ObservationIgnored private let app: AppViewModel
    /// The running Add Vaults; a lock cancels it, so the vault being read stops fetching.
    @ObservationIgnored private var importTask: Task<ConnectAzureModel.ImportResult, Never>?

    init(app: AppViewModel) {
        self.app = app
    }

    private var data: VaultDataComponents {
        app.container.data
    }

    /// Whether `az logout` is offered: some tenant is signed in.
    var showsSignOut: Bool {
        tenants.contains { $0.signIn == .signedIn }
    }

    /// The commands that install or sign in to `az`, when no tenant row gives one.
    var setupCommands: [String] {
        switch requirement {
        case .notInstalled, .untrusted: ConnectAzureModel.commands(for: requirement)
        case .notSignedIn: tenants.isEmpty ? ConnectAzureModel.commands(for: requirement) : []
        case .ready, .failed, nil: []
        }
    }

    /// Lists which tenants `az` is signed in to, then the saved vaults.
    func load() async {
        guard app.phase == .unlocked, !isLoading else { return }
        let lockCount = app.lockCount
        isLoading = true
        defer { isLoading = false }
        var listed: [AzureSubscriptionModel] = []
        let found: ConnectAzureModel.Requirement
        do {
            listed = try await data.azureDiscovery.subscriptions()
            found = .ready
        } catch {
            found = ConnectAzureModel.requirement(for: error)
        }
        // A lock while `az` ran has already cleared the group, even if an unlock followed.
        guard app.lockCount == lockCount, app.phase == .unlocked else { return }
        let vaults = (try? data.destinations.destinations(repositoryID: nil)) ?? []
        requirement = found
        tenants = AzureTenantRowModel.rows(vaults: vaults, listed: listed, requirement: found)
    }

    /// **Check Again** after a command run in Terminal.
    func checkAgain() async {
        copiedCommand = nil
        await load()
    }

    func copy(_ command: String) {
        app.container.clipboard.copyCommand(command)
        copiedCommand = command
    }

    /// **Choose Vaults…** of a signed-in tenant.
    func chooseVaults(_ tenant: AzureTenantRowModel) {
        guard tenant.signIn == .signedIn, let tenantID = tenant.tenantID, chooser == nil else { return }
        importResult = nil
        chooser = ConnectAzureModel(app: app, scope: .tenant(tenantID))
    }

    /// **Add Vaults**: imports the checked vaults as Key Vaults of their own, then lists again.
    func addChosenVaults() async {
        guard let chooser, importTask == nil, !chooser.selectedVaults.isEmpty else { return }
        let lockCount = app.lockCount
        isImporting = true
        let task = Task { [weak self] in
            await chooser.importSelected { self?.importingName = $0 }
        }
        importTask = task
        let result = await task.value
        // A lock reset the group, and a sheet opened since is not this import's to close.
        guard app.lockCount == lockCount, importTask == task else { return }
        importTask = nil
        isImporting = false
        importingName = nil
        importResult = result
        closeChooser()
        await load()
    }

    func closeChooser() {
        chooser?.reset()
        chooser = nil
    }

    /// The vault locked: nothing about Azure stays in memory.
    func reset() {
        importTask?.cancel()
        importTask = nil
        closeChooser()
        tenants = []
        requirement = nil
        copiedCommand = nil
        importResult = nil
        importingName = nil
        isImporting = false
    }
}
