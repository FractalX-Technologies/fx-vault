import Foundation
import VaultCore

/// The setup commands FX Vault may run for the user (1.0 brief, "Setup commands run inside FX
/// Vault"). Fixed argv only: the user never types a command, and interactive commands (`gh auth
/// login`, `az login`) stay Copy-only.
public enum SetupCommand: String, Sendable, Hashable, CaseIterable {
    case installGH
    case upgradeGH
    case installAzureCLI

    /// What the user sees, and what Copy puts on the clipboard.
    public var displayText: String {
        "brew " + brewArguments.joined(separator: " ")
    }

    public var brewArguments: [String] {
        switch self {
        case .installGH: ["install", "gh"]
        case .upgradeGH: ["upgrade", "gh"]
        case .installAzureCLI: ["install", "azure-cli"]
        }
    }

    /// The allowlisted command shown as `text`, or nil for anything else.
    public init?(displayText text: String) {
        guard let match = Self.allCases.first(where: { $0.displayText == text }) else { return nil }
        self = match
    }
}

/// What a setup command printed (stdout and stderr, redacted, last lines only).
public struct SetupCommandOutputModel: Sendable, Hashable {
    public let lines: [String]
    public let exitCode: Int32

    public init(lines: [String], exitCode: Int32) {
        self.lines = lines
        self.exitCode = exitCode
    }
}

public enum SetupCommandError: Error, Sendable, Hashable {
    /// No trusted Homebrew in `/opt/homebrew/bin` or `/usr/local/bin`.
    case homebrewNotFound
    case failed(SetupCommandOutputModel)
    case timedOut
    case launchFailed(errno: Int32)
    case cancelled
}

/// Runs a ``SetupCommand`` with Homebrew. `brew` must pass the same trust check as gh
/// (``GHLocator/evaluate(path:source:consent:inspector:)``): never a file or folder someone else
/// can write.
public struct SetupCommandRunner: Sendable {
    /// Homebrew's prefixes on Apple silicon and Intel, in that order.
    public static let homebrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    /// The output keeps its last lines; `brew` prints its progress, which can run long.
    public static let maxOutputLines = 40

    private let runner: any CommandRunning
    private let inspector: any GHFileInspecting
    private let identity: ProcessIdentityModel
    private let workingDirectory: URL

    public init(runner: any CommandRunning, inspector: any GHFileInspecting, identity: ProcessIdentityModel, workingDirectory: URL) {
        self.runner = runner
        self.inspector = inspector
        self.identity = identity
        self.workingDirectory = workingDirectory
    }

    /// The trusted `brew`, or nil.
    public func homebrewPath() -> String? {
        Self.homebrewPaths.first { path in
            inspector.exists(atPath: path)
                && GHLocator.evaluate(path: path, source: .homebrew, consent: nil, inspector: inspector).rejection == nil
        }
    }

    public func run(_ command: SetupCommand) async throws(SetupCommandError) -> SetupCommandOutputModel {
        guard let brew = homebrewPath() else { throw .homebrewNotFound }
        let prefix = ((brew as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: brew),
            arguments: command.brewArguments,
            environment: ProcessEnvironmentBuilder.homebrew(identity: identity, prefix: prefix),
            workingDirectory: workingDirectory,
            timeout: Timeouts.setupCommand
        )
        let result: CommandResult
        do {
            result = try await runner.run(spec)
        } catch {
            switch error {
            case .cancelled: throw .cancelled
            case .launchFailed(let errno): throw .launchFailed(errno: errno)
            }
        }
        if result.didTimeOut { throw .timedOut }
        let stdout = result.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        result.stdout.wipe()
        let text = StderrRedactor.redact(stdout + "\n" + result.stderr)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).suffix(Self.maxOutputLines)
        let output = SetupCommandOutputModel(lines: Array(lines), exitCode: result.exitCode)
        guard result.isSuccess else { throw .failed(output) }
        return output
    }
}
