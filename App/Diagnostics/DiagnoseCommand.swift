import Foundation
import VaultData

/// `FX Vault --diagnose` (v0.1.1): prints a JSON report about Touch ID readiness to stdout and
/// exits, before SwiftUI, the app delegate, the vault or the database start. Run it on the
/// installed app from Terminal:
///
/// ```sh
/// "/Applications/FX Vault.app/Contents/MacOS/FXVault" --diagnose
/// ```
///
/// It shows no window and no prompt, never opens the vault, never reads a keychain item and
/// prints no secret (``DiagnosticReportModel``).
nonisolated enum DiagnoseCommand {
    static let argument = "--diagnose"

    /// True when `--diagnose` follows the executable path.
    static func isRequested(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(argument)
    }

    /// Called first thing by the entry point: when `--diagnose` was passed, writes the report and
    /// exits; otherwise returns at once.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard isRequested(arguments: arguments) else { return }
        let report = DiagnosticReporter.makeReport(
            infoDictionary: Bundle.main.infoDictionary,
            capabilities: BuildCapabilities(),
            probe: KeychainProbe()
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

    private static let encodingFailure = "FX Vault: the diagnostic report could not be encoded.\n"
}
