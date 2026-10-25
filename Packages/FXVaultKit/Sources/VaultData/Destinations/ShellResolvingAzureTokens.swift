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
