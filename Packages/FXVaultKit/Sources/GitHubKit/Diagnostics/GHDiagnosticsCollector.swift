import Foundation
import VaultCore

/// Collects ``GHDiagnosticsModel`` (v0.3.1). Read-only: it inspects every gh candidate (running
/// `gh --version` only on trusted ones) and, when a gh was accepted, runs
/// `gh auth status --hostname github.com --json hosts` without a token (A3). No database, no
/// token fetch, nothing written anywhere.
public struct GHDiagnosticsCollector: Sendable {
    private let runner: any CommandRunning
    private let identity: ProcessIdentityModel
    private let workingDirectory: URL
    private let fileInspector: any GHFileInspecting

    public init(
        runner: any CommandRunning,
        identity: ProcessIdentityModel,
        workingDirectory: URL,
        fileInspector: any GHFileInspecting = SystemGHFileInspector()
    ) {
        self.runner = runner
        self.identity = identity
        self.workingDirectory = workingDirectory
        self.fileInspector = fileInspector
    }

    /// `shell` is the probed shell environment (``ShellEnvironmentResolver/resolve()``).
    public func collect(
        shell: ShellEnvironmentModel,
        overridePath: String?,
        trustedBinary: GHTrustedBinaryModel?
    ) async -> GHDiagnosticsModel {
        let locator = GHLocator(runner: runner, identity: identity, workingDirectory: workingDirectory, fileInspector: fileInspector)
        let report = await locator.inspect(
            overridePath: overridePath,
            shell: shell,
            trustedBinary: trustedBinary,
            checksEveryVersion: true
        )
        var listing: GHAccountListingModel?
        var accountsError: GHError?
        if let installation = report.installation {
            let service = GHCommandService(
                installation: installation,
                identity: identity,
                shell: shell,
                workingDirectory: workingDirectory,
                runner: runner
            )
            do {
                listing = try await GHAuthService(service: service, tokenCache: GHTokenCache()).listing()
            } catch {
                accountsError = error
            }
        }
        return GHDiagnosticsModel(
            shell: shell,
            overridePath: overridePath,
            trustedBinary: trustedBinary,
            trustedOwnerName: trustedBinary.flatMap { fileInspector.userName(for: $0.ownerUID) },
            report: report,
            listing: listing,
            accountsError: accountsError
        )
    }
}
