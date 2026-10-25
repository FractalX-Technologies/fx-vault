import GitHubKit
import Observation
import SwiftUI
import VaultData

/// **Run** for the allowlisted setup commands (1.0), shared by the gh setup screen and Connect
/// Azure: whether this Mac's Homebrew can run them, the one running now, and the last result.
@Observable
final class SetupCommandRunState {
    /// A trusted Homebrew can run the allowlisted commands: their rows offer **Run**.
    private(set) var canRun = false
    private(set) var running: SetupCommand?
    /// The last **Run**: its output, and whether it succeeded.
    private(set) var lastRun: SetupRunModel?

    @ObservationIgnored private let github: GitHubEnvironmentRepository

    init(github: GitHubEnvironmentRepository) {
        self.github = github
    }

    /// The allowlisted command behind a row, when this Mac can run it.
    func runnable(_ command: String) -> SetupCommand? {
        canRun ? SetupCommand(displayText: command) : nil
    }

    func loadAvailability() async {
        canRun = await github.canRunSetupCommands()
    }

    /// Runs the command with Homebrew and keeps its output. True when it succeeded.
    func run(_ command: SetupCommand) async -> Bool {
        guard running == nil, runnable(command.displayText) != nil else { return false }
        running = command
        lastRun = nil
        defer { running = nil }
        do {
            let output = try await github.runSetupCommand(command)
            lastRun = SetupRunModel(command: command, lines: output.lines, failure: nil)
            return true
        } catch {
            lastRun = SetupRunModel(command: command, lines: error.outputLines, failure: error.localizedMessage)
            return false
        }
    }
}

/// The commands to run, in order: Copy on each, **Run** on the allowlisted ones, the output of
/// the last run and what was copied.
struct SetupCommandList: View {
    let commands: [String]
    let runs: SetupCommandRunState
    let copiedCommand: String?
    /// "Copied <command>. Run it in Terminal, …": where to run it and what to do next.
    let copiedMessage: (String) -> String
    let onRun: (SetupCommand) -> Void
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ForEach(commands, id: \.self) { command in
                CommandRow(
                    command: command,
                    onRun: runs.runnable(command).map { runnable in { onRun(runnable) } },
                    isRunning: runs.running != nil,
                    onCopy: onCopy
                )
            }
            if let run = runs.lastRun {
                if !run.lines.isEmpty {
                    CommandOutputView(lines: run.lines)
                }
                Text(Self.status(run))
                    .fxTextStyle(.caption)
                    .foregroundStyle(run.failure == nil ? Theme.Colors.mutedText : Theme.Colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if runs.running != nil {
                Text(String(localized: "setupCommand.running", defaultValue: "Running… FX Vault runs only this command."))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
            if let copiedCommand {
                Text(copiedMessage(copiedCommand))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
    }

    private static func status(_ run: SetupRunModel) -> String {
        if let failure = run.failure { return failure }
        return String(localized: "setupCommand.done", defaultValue: "Done · \(run.command.displayText) · checked again")
    }
}

/// One **Run** of a setup command: the last lines it printed, and why it failed (nil on success).
struct SetupRunModel: Equatable {
    let command: SetupCommand
    let lines: [String]
    let failure: String?
}

extension SetupCommandError {
    var outputLines: [String] {
        if case .failed(let output) = self { return output.lines }
        return []
    }

    var localizedMessage: String {
        switch self {
        case .homebrewNotFound:
            String(localized: "setupCommand.homebrewNotFound", defaultValue: "Homebrew was not found, or someone else can change it. Copy the command and run it in Terminal.")
        case .failed(let output):
            String(localized: "setupCommand.failed", defaultValue: "The command failed (exit \(output.exitCode)).")
        case .timedOut:
            String(localized: "setupCommand.timedOut", defaultValue: "The command took too long and was stopped.")
        case .launchFailed:
            String(localized: "setupCommand.launchFailed", defaultValue: "Homebrew could not be started.")
        case .cancelled:
            String(localized: "setupCommand.cancelled", defaultValue: "The command was stopped.")
        }
    }
}
