import Dispatch
import Foundation
import GitHubKit
import os
import VaultData

/// `FX Vault --diagnose` (v0.1.1): prints a JSON report about Touch ID readiness and, since
/// v0.3.1, the GitHub CLI to stdout and exits, before SwiftUI, the app delegate, the vault or the
/// database start. Run it on the installed app from Terminal:
///
/// ```sh
/// "/Applications/FX Vault.app/Contents/MacOS/FXVault" --diagnose
/// ```
///
/// It shows no window and no prompt, never opens the vault, never reads a keychain item and
/// prints no secret (``DiagnosticReportModel``). For the `gh` section it runs the user's shell
/// probe, `gh --version` of every trusted candidate and `gh auth status --json hosts` (no token),
/// exactly as the app does at launch.
nonisolated enum DiagnoseCommand {
    static let argument = "--diagnose"

    /// The command Settings › Advanced shows: this app's own executable in single quotes, so a
    /// pasted `$` or backtick in the path is never expanded (a `'` becomes `'\''`).
    static func terminalCommand(executablePath: String? = Bundle.main.executablePath) -> String {
        let path = executablePath ?? "/Applications/FX Vault.app/Contents/MacOS/FXVault"
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) \(argument)"
    }

    /// True when `--diagnose` follows the executable path.
    static func isRequested(arguments: [String]) -> Bool {
        #if FXVAULT_UI_TESTING
        // The UI-testing host never runs the live probes (real shell, gh and keychain).
        return false
        #else
        return arguments.dropFirst().contains(argument)
        #endif
    }

    /// Called first thing by the entry point: when `--diagnose` was passed, writes the report and
    /// exits; otherwise returns at once.
    @MainActor
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard isRequested(arguments: arguments) else { return }
        let preferences = PreferencesManager(store: UserDefaultsPreferencesStore())
        let gh = collectGHDiagnostics(
            overridePath: preferences.ghPathOverride,
            trustedBinary: preferences.trustedGHBinary
        )
        let report = DiagnosticReporter.makeReport(
            infoDictionary: Bundle.main.infoDictionary,
            capabilities: BuildCapabilities(),
            probe: KeychainProbe(),
            gh: gh
        )
        do {
            // The one stdout writer of the app (no print(); never logs values).
            FileHandle.standardOutput.write(try report.jsonData())
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data(encodingFailure.utf8))
            exit(EXIT_FAILURE)
        }
    }

    /// Runs ``liveGHDiagnostics(overridePath:trustedBinary:)`` and waits for it. The process has
    /// no run loop yet and nothing in GitHubKit needs the main actor, so blocking here is safe.
    static func collectGHDiagnostics(overridePath: String?, trustedBinary: GHTrustedBinaryModel?) -> GHDiagnosticsModel {
        let result = OSAllocatedUnfairLock<GHDiagnosticsModel?>(initialState: nil)
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            let model = await liveGHDiagnostics(overridePath: overridePath, trustedBinary: trustedBinary)
            result.withLock { $0 = model }
            finished.signal()
        }
        finished.wait()
        return result.withLock { $0 }
            ?? .unavailable(.cancelled, overridePath: overridePath, trustedBinary: trustedBinary)
    }

    /// The real shell probe, `GHLocator` and `gh auth status`, in the app's empty working
    /// directory with the app's child environments.
    static func liveGHDiagnostics(overridePath: String?, trustedBinary: GHTrustedBinaryModel?) async -> GHDiagnosticsModel {
        let workingDirectory: URL
        do {
            workingDirectory = try EmptyWorkingDirectory.prepareDefault()
        } catch {
            return .unavailable(error, overridePath: overridePath, trustedBinary: trustedBinary)
        }
        let identity = ProcessIdentityModel.current()
        let runner = ProcessRunner()
        let shell: ShellEnvironmentModel
        do {
            shell = try await ShellEnvironmentResolver(runner: runner, identity: identity, workingDirectory: workingDirectory).resolve()
        } catch {
            shell = .empty
        }
        return await GHDiagnosticsCollector(runner: runner, identity: identity, workingDirectory: workingDirectory)
            .collect(shell: shell, overridePath: overridePath, trustedBinary: trustedBinary)
    }

    private static let encodingFailure = "FX Vault: the diagnostic report could not be encoded.\n"
}
