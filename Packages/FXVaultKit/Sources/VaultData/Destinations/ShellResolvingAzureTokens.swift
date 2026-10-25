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
    private let cli: ShellResolvingAzureCLI
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
        cli = ShellResolvingAzureCLI(
            github: github,
            runner: runner,
            identity: identity,
            workingDirectory: workingDirectory,
            fileInspector: fileInspector
        )
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
        let provider = AzureCLITokenProvider(cli: await cli.resolve(), clock: clock)
        self.provider = provider
        return provider
    }
}

/// The ``AzureCLIRunner`` for the probed login-shell PATH, or for no shell when the probe failed
/// (`az` is then looked up in the fixed folders). Shared by the token provider and discovery.
struct ShellResolvingAzureCLI: Sendable {
    let github: GitHubEnvironmentRepository
    let runner: any CommandRunning
    let identity: ProcessIdentityModel
    let workingDirectory: URL
    let fileInspector: any GHFileInspecting

    func resolve() async -> AzureCLIRunner {
        let shell = (try? await github.shellEnvironment()) ?? .empty
        return AzureCLIRunner(
            runner: runner,
            locator: AzureCLILocator(fileInspector: fileInspector),
            identity: identity,
            shell: shell,
            workingDirectory: workingDirectory
        )
    }
}
