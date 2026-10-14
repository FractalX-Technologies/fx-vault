import Foundation
import os
import VaultCore

/// A scripted ``CommandRunning`` for tests and previews (tasks/todo.md §12.2).
///
/// - Matches each spec's argv against queued one-shot responses (first match wins, FIFO),
///   then against persistent stubs; unmatched calls exit 1 with `fake: no stub`.
/// - Records every invocation, including a copy of stdin, then wipes the payload as the real
///   runner does. Recorded stdin is test data; never use the fake with real secrets.
public final class FakeCommandRunner: CommandRunning, Sendable {
    /// One recorded call.
    public struct Invocation: Sendable {
        public let executablePath: String
        public let arguments: [String]
        public let environment: [String: String]
        public let workingDirectory: URL
        public let stdin: Data
        public let timeout: Duration
    }

    /// A scripted outcome.
    public struct Response: Sendable {
        public var exitCode: Int32
        public var stdout: Data
        public var stderr: String
        public var didTimeOut: Bool
        /// Report stdout as cut at the runner's cap.
        public var isStdoutTruncated: Bool
        /// Throw this instead of returning a result.
        public var error: CommandRunnerError?

        public init(
            exitCode: Int32 = 0,
            stdout: Data = Data(),
            stderr: String = "",
            didTimeOut: Bool = false,
            isStdoutTruncated: Bool = false,
            error: CommandRunnerError? = nil
        ) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.didTimeOut = didTimeOut
            self.isStdoutTruncated = isStdoutTruncated
            self.error = error
        }

        /// Exit 0 with `stdout` as UTF-8.
        public static func success(_ stdout: String = "") -> Response {
            Response(stdout: Data(stdout.utf8))
        }

        /// A failure with `stderr`.
        public static func failure(exitCode: Int32 = 1, stderr: String, stdout: String = "") -> Response {
            Response(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: stderr)
        }
    }

    /// Decides whether a response applies to an argv.
    public typealias Matcher = @Sendable ([String]) -> Bool

    private struct Entry: Sendable {
        let matcher: Matcher
        let response: Response
    }

    private struct State: Sendable {
        var queued: [Entry] = []
        var stubs: [Entry] = []
        var invocations: [Invocation] = []
    }

    /// The exit code for calls nothing matched.
    public static let unmatchedExitCode: Int32 = 1
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Queues a one-shot response for the next matching call.
    public func enqueue(_ response: Response, matching matcher: @escaping Matcher = { _ in true }) {
        state.withLock { $0.queued.append(Entry(matcher: matcher, response: response)) }
    }

    /// Adds a persistent response for every call whose argv starts with `prefix`.
    public func stub(argumentsPrefix prefix: [String], with response: Response) {
        state.withLock { state in
            state.stubs.append(Entry(matcher: { Array($0.prefix(prefix.count)) == prefix }, response: response))
        }
    }

    /// Every call so far, in order.
    public var invocations: [Invocation] {
        state.withLock { $0.invocations }
    }

    public func run(_ spec: CommandSpec) async throws(CommandRunnerError) -> CommandResult {
        let stdin = spec.stdin.storage?.withUnsafeBytes { Data($0) } ?? Data()
        spec.stdin.discard()
        let invocation = Invocation(
            executablePath: spec.executableURL.path,
            arguments: spec.arguments,
            environment: spec.environment,
            workingDirectory: spec.workingDirectory,
            stdin: stdin,
            timeout: spec.timeout
        )
        let response = state.withLock { state -> Response? in
            state.invocations.append(invocation)
            if let index = state.queued.firstIndex(where: { $0.matcher(spec.arguments) }) {
                return state.queued.remove(at: index).response
            }
            return state.stubs.first(where: { $0.matcher(spec.arguments) })?.response
        }
        guard let response else {
            return CommandResult(exitCode: Self.unmatchedExitCode, stdout: SecretBytes(count: 0), stderr: "fake: no stub")
        }
        if let error = response.error {
            throw error
        }
        var stdout = response.stdout
        return CommandResult(
            exitCode: response.exitCode,
            didTimeOut: response.didTimeOut,
            stdout: SecretBytes(wipingSource: &stdout),
            stderr: response.stderr,
            isStdoutTruncated: response.isStdoutTruncated
        )
    }
}
