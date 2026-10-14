import Foundation
import VaultCore

/// A past gh write, used to seed the throttle at launch from `sync_journal` (D12).
public struct GHWriteRecordModel: Sendable, Hashable {
    public let date: Date
    public let cost: Int

    public init(date: Date, cost: Int) {
        self.date = date
        self.cost = cost
    }
}

/// One serial gh queue per account (tasks/todo.md D12, §7.3).
///
/// - Commands run one at a time, in arrival order.
/// - Writes are throttled to `Limits.writesPerMinute` per minute and `Limits.writesPerHour`
///   per hour (costs per ``GHCommand/writeCost``), with a `Timeouts.writeBatchGap` gap once more
///   than `Limits.writeBatchGapThreshold` writes fall in the last minute. When the hourly budget
///   would need more than a minute's wait the call throws ``GHError/writeBudgetExhausted`` and
///   the remaining items stay pending.
/// - Rate limiting waits `Timeouts.rateLimitBackoff` and retries up to
///   `Limits.rateLimitRetries` times, then throws ``GHError/rateLimited``.
/// - Idempotent commands retry transient failures (5xx, network, timeout, indeterminate) up to
///   `Limits.idempotentRetries` times, waiting `Timeouts.idempotentRetryBackoff × attempt`.
///   `gh repo create` is never retried.
/// - ``GHError/tokenRevoked``: the token is refreshed once (A4); if it changed, the command is
///   retried once.
/// - The command's stdin value is wiped when the call finishes, whatever the outcome.
public actor GHCommandScheduler {
    public nonisolated let accountLogin: String
    private let service: GHCommandService
    private let auth: GHAuthService
    private let clock: any VaultClock
    private var throttle = WriteThrottle()
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(accountLogin: String, service: GHCommandService, auth: GHAuthService, clock: any VaultClock) {
        self.accountLogin = accountLogin
        self.service = service
        self.auth = auth
        self.clock = clock
    }

    /// Seeds the throttle with writes made before launch (the journal's last hour).
    public func seed(recentWrites: [GHWriteRecordModel]) {
        let now = clock.now
        let uptime = clock.uptime
        for record in recentWrites {
            let age = Duration.seconds(now.timeIntervalSince(record.date))
            guard age >= .zero, age < Timeouts.throttleHourWindow else { continue }
            throttle.record(cost: record.cost, at: uptime - age)
        }
    }

    /// Write cost used in the last hour (the "412 of 450" summary line, §7.2).
    public var writesInLastHour: Int {
        throttle.used(within: Timeouts.throttleHourWindow, now: clock.uptime)
    }

    /// `Limits.writesPerHour` minus ``writesInLastHour`` (never negative).
    public var remainingHourlyBudget: Int {
        max(Limits.writesPerHour - writesInLastHour, 0)
    }

    /// Runs `command` with serialization, throttling and the retry rules above.
    public func run(_ command: GHCommand) async throws(GHError) -> GHCommandOutput {
        await acquire()
        defer {
            release()
            command.wipe()
        }
        var rateLimitRetries = 0
        var transientRetries = 0
        var didRefreshToken = false
        while true {
            if Task.isCancelled { throw .cancelled }
            if command.writeCost > 0 {
                try await waitForWriteBudget(cost: command.writeCost)
            }
            let token = command.operation.requiresToken ? try await auth.token(for: accountLogin) : nil
            defer { token?.wipe() }
            do {
                let output = try await service.execute(command, token: token)
                recordAttempt(of: command)
                return output
            } catch {
                if Self.processRan(for: error) {
                    recordAttempt(of: command)
                }
                switch error {
                case .tokenRevoked where command.operation.requiresToken && !didRefreshToken:
                    didRefreshToken = true
                    guard let token, try await auth.refreshToken(for: accountLogin, replacing: token) else {
                        throw error
                    }
                case .rateLimited where rateLimitRetries < Limits.rateLimitRetries:
                    rateLimitRetries += 1
                    try await sleep(for: Timeouts.rateLimitBackoff)
                case _ where error.isTransient && command.operation.isIdempotent
                    && transientRetries < Limits.idempotentRetries:
                    transientRetries += 1
                    try await sleep(for: Timeouts.idempotentRetryBackoff * transientRetries)
                default:
                    throw error
                }
            }
        }
    }

    // MARK: - Throttle

    private func waitForWriteBudget(cost: Int) async throws(GHError) {
        while true {
            switch throttle.decision(forCost: cost, now: clock.uptime) {
            case .proceed:
                return
            case .wait(let duration):
                try await sleep(for: duration)
            case .exhausted:
                throw .writeBudgetExhausted
            }
        }
    }

    private func recordAttempt(of command: GHCommand) {
        guard command.writeCost > 0 else { return }
        throttle.record(cost: command.writeCost, at: clock.uptime)
    }

    /// False for failures that happen before gh could reach GitHub.
    private static func processRan(for error: GHError) -> Bool {
        switch error {
        case .invalidInput, .forbiddenArgument, .launchFailed, .notInstalled, .cancelled: false
        default: true
        }
    }

    private func sleep(for duration: Duration) async throws(GHError) {
        do {
            try await clock.sleep(for: duration)
        } catch {
            throw .cancelled
        }
    }

    // MARK: - Serial queue

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot to the next waiter (it stays busy) or frees it.
    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// The write budget arithmetic (D12). Pure; times are monotonic uptime.
struct WriteThrottle: Sendable {
    struct Entry: Sendable, Hashable {
        let time: Duration
        let cost: Int
    }

    enum Decision: Sendable, Hashable {
        case proceed
        case wait(Duration)
        case exhausted
    }

    private(set) var entries: [Entry] = []

    mutating func record(cost: Int, at time: Duration) {
        entries.append(Entry(time: time, cost: cost))
        entries.sort { $0.time < $1.time }
    }

    func used(within window: Duration, now: Duration) -> Int {
        entries.filter { now - $0.time < window }.reduce(0) { $0 + $1.cost }
    }

    func decision(forCost cost: Int, now: Duration) -> Decision {
        let hourWindow = Timeouts.throttleHourWindow
        let minuteWindow = Timeouts.throttleMinuteWindow
        if used(within: hourWindow, now: now) + cost > Limits.writesPerHour {
            let wait = waitUntilFits(cost: cost, limit: Limits.writesPerHour, window: hourWindow, now: now)
            return wait > minuteWindow ? .exhausted : .wait(wait)
        }
        if used(within: minuteWindow, now: now) + cost > Limits.writesPerMinute {
            return .wait(waitUntilFits(cost: cost, limit: Limits.writesPerMinute, window: minuteWindow, now: now))
        }
        let recentCount = entries.filter { now - $0.time < minuteWindow }.count
        if recentCount >= Limits.writeBatchGapThreshold, let last = entries.last {
            let sinceLast = now - last.time
            if sinceLast < Timeouts.writeBatchGap {
                return .wait(Timeouts.writeBatchGap - sinceLast)
            }
        }
        return .proceed
    }

    /// How long until enough of the oldest entries leave `window` for `cost` to fit.
    private func waitUntilFits(cost: Int, limit: Int, window: Duration, now: Duration) -> Duration {
        var used = used(within: window, now: now)
        var wait = Duration.zero
        for entry in entries where now - entry.time < window {
            if used + cost <= limit { break }
            used -= entry.cost
            wait = entry.time + window - now
        }
        return max(wait, .zero)
    }
}
