import Darwin
import Foundation
import os
import VaultCore

/// Runs child processes with the rules of tasks/todo.md §5.10.
///
/// - `posix_spawn` with an absolute executable and an argv array; never a shell string.
/// - The child gets exactly ``CommandSpec/environment`` and ``CommandSpec/workingDirectory``,
///   its own process group, default signal dispositions, and no file descriptors other than
///   0, 1 and 2 (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
/// - stdin is always a pipe: the payload is written on a background thread, the pipe is closed,
///   and the payload is wiped. Writing never raises `SIGPIPE` (`F_SETNOSIGPIPE`).
/// - stdout and stderr are drained concurrently and capped; bytes over the cap are read and
///   discarded so the child never blocks. stdout lands in a buffer that is zeroed whenever it
///   grows and after it is copied into the result's `SecretBytes`.
/// - On timeout or cancellation the process group gets `SIGTERM`, then `SIGKILL` after
///   `Timeouts.processKillGrace`. Exit is detected without reaping first, so a signal can never
///   reach a recycled pid.
///
/// Stateless and `Sendable`; one instance can run many processes concurrently.
public struct ProcessRunner: CommandRunning {
    private let clock: any VaultClock

    /// `clock` drives the timeout and the kill grace period.
    public init(clock: any VaultClock = SystemClock()) {
        self.clock = clock
    }

    public func run(_ spec: CommandSpec) async throws(CommandRunnerError) -> CommandResult {
        if Task.isCancelled {
            spec.stdin.discard()
            throw .cancelled
        }
        let child: SpawnedChild
        do {
            child = try SpawnedChild.spawn(spec)
        } catch {
            spec.stdin.discard()
            throw error
        }
        child.startStdinWriter(payload: spec.stdin)
        child.startExitWaiter()

        let clock = self.clock
        let state = child.state
        let watchdog = Task {
            do { try await clock.sleep(for: spec.timeout) } catch { return }
            state.markTimedOut()
            state.signalGroup(SIGTERM)
            do { try await clock.sleep(for: Timeouts.processKillGrace) } catch { return }
            state.signalGroup(SIGKILL)
        }

        let status = await withTaskCancellationHandler {
            await state.waitForExit()
        } onCancel: {
            state.markCancelled()
            state.signalGroup(SIGTERM)
            Task {
                do { try await clock.sleep(for: Timeouts.processKillGrace) } catch { return }
                state.signalGroup(SIGKILL)
            }
        }
        watchdog.cancel()

        // A grandchild that inherited stdout/stderr could keep the pipes open after the child
        // exits; stop reading after the grace period in that case.
        let stdoutCollector = child.stdoutCollector
        let stderrCollector = child.stderrCollector
        let drainGuard = Task {
            do { try await clock.sleep(for: Timeouts.processKillGrace) } catch { return }
            stdoutCollector.forceFinish()
            stderrCollector.forceFinish()
        }
        await stdoutCollector.waitUntilFinished()
        await stderrCollector.waitUntilFinished()
        drainGuard.cancel()

        let stdout = stdoutCollector.takeOutput()
        let stderr = stderrCollector.takeOutput()
        let stderrText = stderr.bytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        stderr.bytes.wipe()

        if state.wasCancelled {
            stdout.bytes.wipe()
            throw .cancelled
        }

        let termination = WaitStatus(rawValue: status)
        return CommandResult(
            exitCode: termination.exitCode,
            terminationSignal: termination.signal,
            didTimeOut: state.didTimeOut,
            stdout: stdout.bytes,
            stderr: stderrText,
            isStdoutTruncated: stdout.isTruncated,
            isStderrTruncated: stderr.isTruncated
        )
    }
}

// MARK: - Wait status

/// Decodes a `waitpid` status (the `WIFEXITED` family are C macros Swift cannot import).
private struct WaitStatus {
    private static let signalMask: Int32 = 0x7f
    private static let exitShift: Int32 = 8
    private static let exitMask: Int32 = 0xff
    /// Shells report a signal death as 128 + signal; the runner does the same.
    private static let signalExitBase: Int32 = 128

    let exitCode: Int32
    let signal: Int32?

    init(rawValue: Int32) {
        let signal = rawValue & Self.signalMask
        if signal == 0 {
            exitCode = (rawValue >> Self.exitShift) & Self.exitMask
            self.signal = nil
        } else {
            exitCode = Self.signalExitBase + signal
            self.signal = signal
        }
    }
}

// MARK: - Child state

/// Exit, timeout and cancellation state of one child, shared by the waiter thread, the
/// watchdog and the caller.
private final class ChildState: Sendable {
    private struct State: Sendable {
        var hasExited = false
        var status: Int32?
        var continuation: CheckedContinuation<Int32, Never>?
        var didTimeOut = false
        var wasCancelled = false
    }

    let pid: pid_t
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(pid: pid_t) {
        self.pid = pid
    }

    var didTimeOut: Bool {
        state.withLock { $0.didTimeOut }
    }

    var wasCancelled: Bool {
        state.withLock { $0.wasCancelled }
    }

    func markTimedOut() {
        state.withLock { $0.didTimeOut = true }
    }

    func markCancelled() {
        state.withLock { $0.wasCancelled = true }
    }

    /// Signals the child's process group unless the child has exited. Runs under the lock, so
    /// the waiter cannot reap (and free the pid) between the check and the signal.
    func signalGroup(_ signal: Int32) {
        let pid = self.pid
        state.withLock { state in
            guard !state.hasExited else { return }
            _ = killpg(pid, signal)
        }
    }

    /// Called by the waiter thread once the child has exited but before it is reaped.
    func markExited() {
        state.withLock { $0.hasExited = true }
    }

    /// Called by the waiter thread after reaping.
    func finish(status: Int32) {
        let continuation = state.withLock { state -> CheckedContinuation<Int32, Never>? in
            state.status = status
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: status)
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let status = state.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.continuation = continuation
                return nil
            }
            if let status {
                continuation.resume(returning: status)
            }
        }
    }
}

// MARK: - Spawning

/// A started child with its pipes.
private struct SpawnedChild: Sendable {
    let state: ChildState
    let stdinFD: Int32
    let stdoutCollector: OutputCollector
    let stderrCollector: OutputCollector

    static func spawn(_ spec: CommandSpec) throws(CommandRunnerError) -> SpawnedChild {
        let stdinPipe = try makePipe()
        let stdoutPipe: (read: Int32, write: Int32)
        let stderrPipe: (read: Int32, write: Int32)
        do {
            stdoutPipe = try makePipe()
        } catch {
            closeAll([stdinPipe.read, stdinPipe.write])
            throw error
        }
        do {
            stderrPipe = try makePipe()
        } catch {
            closeAll([stdinPipe.read, stdinPipe.write, stdoutPipe.read, stdoutPipe.write])
            throw error
        }
        let allDescriptors = [
            stdinPipe.read, stdinPipe.write,
            stdoutPipe.read, stdoutPipe.write,
            stderrPipe.read, stderrPipe.write,
        ]

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe.read, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.write, STDERR_FILENO)
        let chdirResult = spec.workingDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            return posix_spawn_file_actions_addchdir(&fileActions, path)
        }
        guard chdirResult == 0 else {
            closeAll(allDescriptors)
            throw .launchFailed(errno: chdirResult)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        var blockedSignals = sigset_t()
        sigemptyset(&blockedSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setsigmask(&attributes, &blockedSignals)
        posix_spawnattr_setpgroup(&attributes, 0)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv: [UnsafeMutablePointer<CChar>?] =
            ([spec.executableURL.path] + spec.arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            // The environment may hold GH_TOKEN: zero each string before freeing it.
            for entry in envp {
                guard let entry else { continue }
                let length = strlen(entry)
                _ = memset_s(entry, length, 0, length)
                free(entry)
            }
        }

        var pid: pid_t = 0
        let spawnResult = spec.executableURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            return posix_spawn(&pid, path, &fileActions, &attributes, argv, envp)
        }
        guard spawnResult == 0 else {
            closeAll(allDescriptors)
            throw .launchFailed(errno: spawnResult)
        }

        // The child holds its own copies; the parent keeps only its ends.
        closeAll([stdinPipe.read, stdoutPipe.write, stderrPipe.write])
        _ = fcntl(stdinPipe.write, F_SETNOSIGPIPE, 1)

        return SpawnedChild(
            state: ChildState(pid: pid),
            stdinFD: stdinPipe.write,
            stdoutCollector: OutputCollector(fileDescriptor: stdoutPipe.read, cap: spec.maxStdoutBytes),
            stderrCollector: OutputCollector(fileDescriptor: stderrPipe.read, cap: spec.maxStderrBytes)
        )
    }

    /// Writes the payload on a dedicated thread (the write may block until the child reads),
    /// closes the pipe, then wipes the payload.
    func startStdinWriter(payload: StdinPayload) {
        let descriptor = stdinFD
        let thread = Thread {
            payload.storage?.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = write(descriptor, base + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
            close(descriptor)
            payload.discard()
        }
        thread.start()
    }

    /// Waits for the child on a dedicated thread: first without reaping (so signals stay safe),
    /// then reaps it and reports the status.
    func startExitWaiter() {
        let state = self.state
        let pid = state.pid
        let thread = Thread {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            state.markExited()
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            state.finish(status: status)
        }
        thread.start()
    }

    private static func makePipe() throws(CommandRunnerError) -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw .launchFailed(errno: errno)
        }
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        return (descriptors[0], descriptors[1])
    }

    private static func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors {
            close(descriptor)
        }
    }
}

// MARK: - Output collection

/// Drains one pipe with a dispatch read source into a capped, wipe-on-grow buffer.
private final class OutputCollector: @unchecked Sendable {
    /// Bytes read per `read(2)` call.
    private static let chunkSize = 64 * Limits.bytesPerKiB

    struct Output {
        let bytes: SecretBytes
        let isTruncated: Bool
    }

    private struct State {
        var isFinished = false
        var isTruncated = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let descriptor: Int32
    private let cap: Int
    private let queue = DispatchQueue(label: "io.fractalx.fxvault.process-output")
    private let source: DispatchSourceRead
    /// Accessed only on `queue` until the source is cancelled, then only by `takeOutput()`.
    private let buffer = WipingBuffer()
    private let scratch: UnsafeMutableRawBufferPointer
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(fileDescriptor: Int32, cap: Int) {
        descriptor = fileDescriptor
        self.cap = max(cap, 0)
        scratch = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Self.chunkSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
        scratch.initializeMemory(as: UInt8.self, repeating: 0)
        let flags = fcntl(fileDescriptor, F_GETFL)
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [self] in
            drain()
        }
        source.setCancelHandler { [self] in
            close(descriptor)
            finish()
        }
        source.activate()
    }

    deinit {
        _ = memset_s(scratch.baseAddress, scratch.count, 0, scratch.count)
        scratch.deallocate()
    }

    /// Stops reading (the pipe may still be held open by a grandchild).
    func forceFinish() {
        source.cancel()
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isFinished = state.withLock { state -> Bool in
                if state.isFinished { return true }
                state.waiters.append(continuation)
                return false
            }
            if isFinished {
                continuation.resume()
            }
        }
    }

    /// The captured bytes. Call once, after ``waitUntilFinished()``. The internal buffer is
    /// wiped.
    func takeOutput() -> Output {
        let isTruncated = state.withLock { $0.isTruncated }
        let bytes = queue.sync { buffer.takeSecretBytes() }
        return Output(bytes: bytes, isTruncated: isTruncated)
    }

    private func drain() {
        guard let base = scratch.baseAddress else { return }
        while true {
            let count = read(descriptor, base, scratch.count)
            if count > 0 {
                append(UnsafeRawBufferPointer(start: base, count: count))
                _ = memset_s(base, count, 0, count)
                continue
            }
            if count == 0 {
                source.cancel()
                return
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                return
            default:
                source.cancel()
                return
            }
        }
    }

    private func append(_ bytes: UnsafeRawBufferPointer) {
        let room = cap - buffer.count
        if bytes.count > room {
            state.withLock { $0.isTruncated = true }
        }
        let kept = min(bytes.count, max(room, 0))
        if kept > 0 {
            buffer.append(UnsafeRawBufferPointer(rebasing: bytes[0..<kept]))
        }
    }

    private func finish() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isFinished = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// A growable byte buffer that zeroes its old storage before freeing it.
private final class WipingBuffer {
    private static let initialCapacity = 4 * Limits.bytesPerKiB
    private static let growthFactor = 2

    private var storage: UnsafeMutableRawBufferPointer?
    private(set) var count = 0

    deinit {
        release()
    }

    func append(_ bytes: UnsafeRawBufferPointer) {
        guard let source = bytes.baseAddress, bytes.count > 0 else { return }
        let needed = count + bytes.count
        let capacity = storage?.count ?? 0
        if needed > capacity {
            var newCapacity = max(capacity, Self.initialCapacity)
            while newCapacity < needed {
                newCapacity *= Self.growthFactor
            }
            let grown = UnsafeMutableRawBufferPointer.allocate(
                byteCount: newCapacity,
                alignment: MemoryLayout<UInt8>.alignment
            )
            grown.initializeMemory(as: UInt8.self, repeating: 0)
            if let old = storage, let oldBase = old.baseAddress, let newBase = grown.baseAddress {
                newBase.copyMemory(from: oldBase, byteCount: count)
            }
            release()
            storage = grown
        }
        guard let base = storage?.baseAddress else { return }
        (base + count).copyMemory(from: source, byteCount: bytes.count)
        count = needed
    }

    /// Copies the contents into a new `SecretBytes`, then wipes and frees the storage.
    func takeSecretBytes() -> SecretBytes {
        let bytes: SecretBytes
        if let storage {
            bytes = SecretBytes(copying: UnsafeRawBufferPointer(rebasing: storage[0..<count]))
        } else {
            bytes = SecretBytes(count: 0)
        }
        release()
        count = 0
        return bytes
    }

    private func release() {
        guard let storage else { return }
        _ = memset_s(storage.baseAddress, storage.count, 0, storage.count)
        storage.deallocate()
        self.storage = nil
    }
}
