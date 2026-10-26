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
        /// Sent to the spec's ``CommandSpec/stderrObserver`` before the call ends (a device code).
        public var streamedStderr: String?
        /// The process "keeps waiting" until the calling task is cancelled, then throws
        /// `.cancelled` (gh polling for an approval that never comes).
        public var waitsForCancellation: Bool

        public init(
            exitCode: Int32 = 0,
            stdout: Data = Data(),
            stderr: String = "",
            didTimeOut: Bool = false,
            isStdoutTruncated: Bool = false,
            error: CommandRunnerError? = nil,
            streamedStderr: String? = nil,
            waitsForCancellation: Bool = false
        ) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.didTimeOut = didTimeOut
            self.isStdoutTruncated = isStdoutTruncated
            self.error = error
            self.streamedStderr = streamedStderr
            self.waitsForCancellation = waitsForCancellation
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
        /// Matches only calls of this executable when set.
        var executablePath: String?
        /// The argv prefix of a stub made with a prefix (so ``replaceStub(argumentsPrefix:with:)``
        /// can find it).
        var prefix: [String]?
        let matcher: Matcher
        let respond: @Sendable (Invocation) -> Response

        init(executablePath: String? = nil, prefix: [String]? = nil, matcher: @escaping Matcher, response: Response) {
            self.init(executablePath: executablePath, prefix: prefix, matcher: matcher) { _ in response }
        }

        init(
            executablePath: String? = nil,
            prefix: [String]? = nil,
            matcher: @escaping Matcher,
            respond: @escaping @Sendable (Invocation) -> Response
        ) {
            self.executablePath = executablePath
            self.prefix = prefix
            self.matcher = matcher
            self.respond = respond
        }

        func matches(_ spec: CommandSpec) -> Bool {
            (executablePath == nil || executablePath == spec.executableURL.path) && matcher(spec.arguments)
        }
    }

    private struct State: Sendable {
        var queued: [Entry] = []
        var stubs: [Entry] = []
        var invocations: [Invocation] = []
    }

    /// The exit code for calls nothing matched.
    public static let unmatchedExitCode: Int32 = 1
    /// The stderr of an unmatched call. Wrappers (a stateful GitHub simulator) match it, together
    /// with ``unmatchedExitCode``, to tell an unscripted call from a scripted failure.
    public static let unmatchedStderr = "fake: no stub"
    private static let cancellationPoll: Duration = .milliseconds(10)
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Queues a one-shot response for the next matching call.
    public func enqueue(_ response: Response, matching matcher: @escaping Matcher = { _ in true }) {
        state.withLock { $0.queued.append(Entry(matcher: matcher, response: response)) }
    }

    /// Adds a persistent response for every call whose argv starts with `prefix`. When several
    /// stubs match, the first one added wins; use ``replaceStub(argumentsPrefix:with:)`` to change
    /// a response later in a test.
    public func stub(argumentsPrefix prefix: [String], with response: Response) {
        state.withLock { state in
            state.stubs.append(Entry(prefix: prefix, matcher: { Array($0.prefix(prefix.count)) == prefix }, response: response))
        }
    }

    /// Replaces every stub made with exactly `prefix` (for any executable) by `response`.
    public func replaceStub(argumentsPrefix prefix: [String], with response: Response) {
        state.withLock { state in
            state.stubs.removeAll { $0.executablePath == nil && $0.prefix == prefix }
            state.stubs.insert(Entry(prefix: prefix, matcher: { Array($0.prefix(prefix.count)) == prefix }, response: response), at: 0)
        }
    }

    /// Adds a persistent response computed from each call whose argv starts with `prefix` (a
    /// stateful stand-in, for example a variable that lists what was last set). Checked before
    /// the other stubs.
    public func respond(argumentsPrefix prefix: [String], with handler: @escaping @Sendable (Invocation) -> Response) {
        state.withLock { state in
            state.stubs.insert(Entry(prefix: prefix, matcher: { Array($0.prefix(prefix.count)) == prefix }, respond: handler), at: 0)
        }
    }

    /// Adds a persistent response for calls of `executablePath` whose argv starts with `prefix`
    /// (several gh binaries in one test). Checked before the stubs that match any executable.
    public func stub(executablePath: String, argumentsPrefix prefix: [String], with response: Response) {
        state.withLock { state in
            let entry = Entry(
                executablePath: executablePath,
                prefix: prefix,
                matcher: { Array($0.prefix(prefix.count)) == prefix },
                response: response
            )
            state.stubs.insert(entry, at: 0)
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
        let entry = state.withLock { state -> Entry? in
            state.invocations.append(invocation)
            if let index = state.queued.firstIndex(where: { $0.matches(spec) }) {
                return state.queued.remove(at: index)
            }
            return state.stubs.first(where: { $0.matches(spec) })
        }
        guard let response = entry?.respond(invocation) else {
            return CommandResult(exitCode: Self.unmatchedExitCode, stdout: SecretBytes(count: 0), stderr: Self.unmatchedStderr)
        }
        if let streamed = response.streamedStderr {
            spec.stderrObserver?(streamed)
        }
        if response.waitsForCancellation {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.cancellationPoll)
            }
            throw .cancelled
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
