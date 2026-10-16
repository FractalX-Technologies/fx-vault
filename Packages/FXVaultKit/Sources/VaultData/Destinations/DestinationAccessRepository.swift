import DestinationKit
import Foundation
import GitHubKit
import os
import VaultCore
import VaultStore

/// Azure tokens through the user's `az login`, built on first use (v0.8.0, R4): `az` needs the
/// probed login-shell PATH, which ``GitHubEnvironmentRepository`` resolves asynchronously, so the
/// ``AzureCLITokenProvider`` is created once the probe is in (or without it, when the probe
/// failed: `az` is then looked up in the fixed folders).
public actor ShellResolvingAzureTokens: AccessTokenProviding {
    private let github: GitHubEnvironmentRepository
    private let runner: any CommandRunning
    private let identity: ProcessIdentityModel
    private let workingDirectory: URL
    private let fileInspector: any GHFileInspecting
    private let clock: any VaultClock
    private var provider: AzureCLITokenProvider?

    public init(
        github: GitHubEnvironmentRepository,
        runner: any CommandRunning,
        identity: ProcessIdentityModel,
        workingDirectory: URL,
        fileInspector: any GHFileInspecting = SystemGHFileInspector(),
        clock: any VaultClock
    ) {
        self.github = github
        self.runner = runner
        self.identity = identity
        self.workingDirectory = workingDirectory
        self.fileInspector = fileInspector
        self.clock = clock
    }

    public func token(tenantID: String?) async throws(DestinationError) -> SecretBytes {
        try await resolved().token(tenantID: tenantID)
    }

    public func invalidate(tenantID: String?) async {
        await provider?.invalidate(tenantID: tenantID)
    }

    /// Drops every cached token (the vault locked).
    public func reset() {
        provider = nil
    }

    private func resolved() async -> AzureCLITokenProvider {
        if let provider { return provider }
        let shell = (try? await github.shellEnvironment()) ?? .empty
        let provider = AzureCLITokenProvider(
            runner: runner,
            locator: AzureCLILocator(fileInspector: fileInspector),
            identity: identity,
            shell: shell,
            workingDirectory: workingDirectory,
            clock: clock
        )
        self.provider = provider
        return provider
    }
}

/// Provider accounts for the destination screens (v0.8.0): checking a token before it is saved,
/// the Supabase projects and the Vercel teams and projects of a connection (the Add Destination
/// pickers), and whether `az` is signed in. Tokens are opened only for the request and wiped.
public struct DestinationAccessRepository: Sendable {
    private let destinations: DestinationRepository
    private let transport: any HTTPTransporting
    private let azureTokens: any AccessTokenProviding
    private let clock: any VaultClock

    public init(
        session: VaultSession,
        transport: any HTTPTransporting,
        azureTokens: any AccessTokenProviding,
        clock: any VaultClock = SystemClock()
    ) {
        destinations = DestinationRepository(session: session, clock: clock)
        self.transport = transport
        self.azureTokens = azureTokens
        self.clock = clock
    }

    /// Checks a Supabase or Vercel token and returns what to remember about its account (a
    /// Vercel username, a Supabase project count), never the token. Does not wipe `token`.
    public func check(_ token: SecretBytes, provider: DestinationProvider) async throws(DestinationError) -> String? {
        switch provider {
        case .supabase:
            let projects = try await SupabaseAccountClient(transport: transport, clock: clock).projects(token: token)
            return String(projects.count)
        case .vercel:
            return try await VercelAccountClient(transport: transport, clock: clock).user(token: token).username
        case .azureKeyVault:
            throw .tokenMissing
        }
    }

    /// The projects a Supabase connection can reach.
    public func supabaseProjects(connectionID: ConnectionID) async throws(DestinationSyncError) -> [SupabaseProjectModel] {
        let token = try openToken(connectionID)
        defer { token.wipe() }
        do throws(DestinationError) {
            return try await SupabaseAccountClient(transport: transport, clock: clock).projects(token: token)
        } catch {
            throw .remote(error)
        }
    }

    /// The account and teams of a Vercel connection.
    public func vercelScopes(connectionID: ConnectionID) async throws(DestinationSyncError) -> (user: VercelUserModel, teams: [VercelTeamModel]) {
        let token = try openToken(connectionID)
        defer { token.wipe() }
        do throws(DestinationError) {
            let client = VercelAccountClient(transport: transport, clock: clock)
            return (try await client.user(token: token), try await client.teams(token: token))
        } catch {
            throw .remote(error)
        }
    }

    /// The projects of a Vercel team (nil: the personal account).
    public func vercelProjects(connectionID: ConnectionID, teamID: String?) async throws(DestinationSyncError) -> [VercelProjectModel] {
        let token = try openToken(connectionID)
        defer { token.wipe() }
        do throws(DestinationError) {
            return try await VercelAccountClient(transport: transport, clock: clock).projects(token: token, teamID: teamID)
        } catch {
            throw .remote(error)
        }
    }

    /// Whether `az` can give a Key Vault token (signed in, and for `tenantID` when given).
    public func checkAzure(tenantID: String?) async throws(DestinationError) {
        let token = try await azureTokens.token(tenantID: tenantID)
        token.wipe()
    }

    private func openToken(_ id: ConnectionID) throws(DestinationSyncError) -> SecretBytes {
        do throws(ConfigRepositoryError) {
            return try destinations.token(of: id)
        } catch .connectionNotFound {
            throw .connectionMissing
        } catch {
            throw .config(error)
        }
    }
}
