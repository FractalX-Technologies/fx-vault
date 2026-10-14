import Darwin
import Foundation
import Testing
@testable import GitHubKit
import VaultCore

/// Real child processes (`/bin/cat`, `/bin/sleep`, `/bin/sh`) through ``ProcessRunner``
/// (tasks/todo.md M2: stdin round trip, timeout kill, output cap).
@Suite("ProcessRunner")
struct ProcessRunnerTests {
    let runner = ProcessRunner()

    private func spec(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String] = ["PATH": "/usr/bin:/bin"],
        stdin: StdinPayload = .empty,
        timeout: Duration = .seconds(10),
        maxStdout: Int = Limits.maxStdoutBytes,
        maxStderr: Int = Limits.maxStderrBytes
    ) -> CommandSpec {
        CommandSpec(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: environment,
            workingDirectory: URL(fileURLWithPath: "/", isDirectory: true),
            stdin: stdin,
            timeout: timeout,
            maxStdoutBytes: maxStdout,
            maxStderrBytes: maxStderr
        )
    }

    @Test func catRoundTripsStdinByteForByte() async throws {
        let bytes: [UInt8] = Array("--'\t\"value\" with spaces\r\n".utf8) + [0, 255, 10]
        let payload = SecretBytes(copying: bytes)
        let result = try await runner.run(spec("/bin/cat", stdin: StdinPayload(transferring: payload)))
        #expect(result.exitCode == 0)
        #expect(result.isSuccess)
        #expect(result.stdout.withUnsafeBytes { Array($0) } == bytes)
        #expect(payload.isWiped, "the runner wipes the payload after writing it")
    }

    @Test func largeStdinDoesNotDeadlock() async throws {
        let size = 2 * Limits.bytesPerMiB
        let payload = SecretBytes(copying: [UInt8](repeating: UInt8(ascii: "x"), count: size))
        let result = try await runner.run(spec("/bin/cat", stdin: StdinPayload(transferring: payload)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == size)
    }

    @Test func emptyStdinReadsEndOfFile() async throws {
        let result = try await runner.run(spec("/bin/cat"))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test func timeoutTerminatesWithSIGTERM() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(spec("/bin/sleep", ["60"], timeout: .milliseconds(300)))
        let elapsed = clock.now - start
        #expect(result.didTimeOut)
        #expect(result.terminationSignal == SIGTERM)
        #expect(!result.isSuccess)
        #expect(elapsed < .seconds(5))
    }

    @Test func timeoutEscalatesToSIGKILLWhenTermIsIgnored() async throws {
        // The shell and its sleep child both ignore SIGTERM; the group gets SIGKILL after the grace.
        let result = try await runner.run(
            spec("/bin/sh", ["-c", "trap '' TERM; /bin/sleep 60"], timeout: .milliseconds(300))
        )
        #expect(result.didTimeOut)
        #expect(result.terminationSignal == SIGKILL)
    }

    @Test func stdoutIsCappedAndFlagged() async throws {
        let cap = 1000
        let result = try await runner.run(
            spec("/bin/sh", ["-c", "/usr/bin/yes | /usr/bin/head -c 200000"], maxStdout: cap)
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == cap)
        #expect(result.isStdoutTruncated)
        #expect(!result.isStderrTruncated)
    }

    @Test func stderrIsCappedAndFlagged() async throws {
        let cap = 64
        let result = try await runner.run(
            spec("/bin/sh", ["-c", "/usr/bin/yes error | /usr/bin/head -c 5000 1>&2"], maxStderr: cap)
        )
        #expect(result.stderr.utf8.count == cap)
        #expect(result.isStderrTruncated)
    }

    @Test func exitCodesAndStderrAreReported() async throws {
        let result = try await runner.run(spec("/bin/sh", ["-c", "echo boom >&2; exit 3"]))
        #expect(result.exitCode == 3)
        #expect(result.stderr == "boom\n")
        #expect(result.terminationSignal == nil)
    }

    @Test func environmentIsExactlyTheSpec() async throws {
        let result = try await runner.run(spec("/usr/bin/env", environment: ["ONLY": "this", "PATH": "/usr/bin"]))
        let lines = result.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
            .split(separator: "\n").map(String.init).sorted()
        #expect(lines == ["ONLY=this", "PATH=/usr/bin"])
    }

    @Test func workingDirectoryIsApplied() async throws {
        let directory = try TemporaryDirectory()
        var command = spec("/bin/pwd")
        command.workingDirectory = directory.url
        let result = try await runner.run(command)
        let output = result.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        #expect(output.trimmingCharacters(in: .newlines) == directory.url.path)
    }

    @Test func childGetsNoInheritedDescriptors() async throws {
        // A descriptor the parent opened without FD_CLOEXEC must not reach the child
        // (POSIX_SPAWN_CLOEXEC_DEFAULT).
        let descriptor = open("/dev/null", O_RDONLY)
        #expect(descriptor > STDERR_FILENO)
        defer { close(descriptor) }
        let script = "if [ -e /dev/fd/\(descriptor) ]; then echo open; else echo closed; fi"
        let result = try await runner.run(spec("/bin/sh", ["-c", script]))
        let output = result.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        #expect(output == "closed\n")
    }

    @Test func missingExecutableFailsToLaunch() async throws {
        let payload = SecretBytes(utf8: "value")
        await #expect(throws: CommandRunnerError.launchFailed(errno: ENOENT)) {
            try await runner.run(spec("/nonexistent/fxvault-gh", stdin: StdinPayload(transferring: payload)))
        }
        #expect(payload.isWiped)
    }

    @Test func cancellationTerminatesTheProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let runner = self.runner
        let command = spec("/bin/sleep", ["60"], timeout: .seconds(60))
        let task = Task { try await runner.run(command) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CommandRunnerError.cancelled) {
            try await task.value
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func descriptionsHideEnvironmentAndArguments() {
        let command = spec("/bin/echo", ["owner-a/repo-a"], environment: ["GH_TOKEN": TestValues.token])
        let text = "\(command) \(String(reflecting: command))"
        #expect(!text.contains(TestValues.token))
        #expect(!text.contains("owner-a"))
    }
}
