import Foundation
import GitHubKit
import Observation
import VaultCore
import VaultData

/// In-app Approve (1.0 B4b, board ConnectGitHub): FX Vault runs `gh auth refresh` for the
/// missing scopes, shows gh's one-time code to enter at github.com/login/device and waits for
/// gh to finish. The code is shown, never logged; nothing else gh prints is kept.
@Observable
final class GHApprovalViewModel: LockObserving {
    enum Phase: Equatable {
        /// gh is starting and hasn't printed its code yet.
        case starting
        /// The code is on screen; gh waits for the approval in the browser.
        case waiting(GHDeviceCodeModel)
        /// The scopes are there (gh finished, or Check Again found them).
        case approved
        case failed(GHApprovalError)
    }

    /// Runs `gh auth refresh` (``GitHubEnvironmentRepository/approveScopes(_:login:codeWait:onDeviceCode:)``).
    typealias Approve = (
        _ scopes: [GHApprovalScope],
        _ login: String,
        _ onDeviceCode: @escaping @Sendable (GHDeviceCodeModel) -> Void
    ) async throws(GHApprovalError) -> Void

    let context: GHApprovalContext
    private(set) var phase: Phase = .starting
    private(set) var isCodeCopied = false
    private(set) var isCommandCopied = false
    private(set) var isChecking = false

    @ObservationIgnored private let approve: Approve
    /// True once gh lists the scopes on the login (`gh auth status` read again).
    @ObservationIgnored private let hasScopes: ([GHApprovalScope], String) async -> Bool
    @ObservationIgnored private let copy: (String) -> Void
    /// The sidebar reads accounts and organization access again.
    @ObservationIgnored private let didApprove: () -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every start and cancel: a run that ended after it was replaced says nothing.
    @ObservationIgnored private var generation = 0

    init(
        context: GHApprovalContext,
        approve: @escaping Approve,
        hasScopes: @escaping ([GHApprovalScope], String) async -> Bool,
        copy: @escaping (String) -> Void,
        didApprove: @escaping () -> Void
    ) {
        self.context = context
        self.approve = approve
        self.hasScopes = hasScopes
        self.copy = copy
        self.didApprove = didApprove
    }

    /// Over the vault's gh (`gh auth refresh`, `gh auth status`), the clipboard for the code and
    /// the command, and a sidebar reload once approved; a lock stops gh.
    convenience init(context: GHApprovalContext, dependencies: FeatureDependencies, codeWait: Duration = Timeouts.ghDeviceCodeWait) {
        let github = dependencies.github
        self.init(
            context: context,
            approve: { scopes, login, onDeviceCode throws(GHApprovalError) in
                try await github.approveScopes(scopes, login: login, codeWait: codeWait, onDeviceCode: onDeviceCode)
            },
            hasScopes: { scopes, login in await github.hasScopes(scopes, login: login) },
            copy: dependencies.clipboard.copyCommand,
            didApprove: { dependencies.actions.refresh(.catalog) }
        )
        dependencies.actions.addLockObserver(self)
    }

    /// What the user can run in Terminal instead, shown with Copy when the run fails.
    var commandText: String {
        GHAuthService.refreshCommandText(scopes: context.scopes)
    }

    var isRunning: Bool {
        task != nil
    }

    // MARK: - Actions

    /// Starts gh (again after a failure).
    func start() {
        cancel()
        phase = .starting
        isCodeCopied = false
        let run = generation
        let context = context
        let approve = approve
        let report: @MainActor (GHDeviceCodeModel) -> Void = { [weak self] code in self?.show(code, run: run) }
        task = Task { [weak self] in
            do throws(GHApprovalError) {
                try await approve(context.scopes, context.login) { code in
                    Task { @MainActor in report(code) }
                }
                self?.end(run, with: .approved)
            } catch {
                self?.end(run, with: .failed(error))
            }
        }
    }

    /// Cancel, or the sheet closing: gh is stopped.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    /// Reads gh's scopes again: once they are all there, gh is stopped and the approval is done.
    func checkAgain() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        guard await hasScopes(context.scopes, context.login) else { return }
        cancel()
        phase = .approved
        didApprove()
    }

    func copyCode() {
        guard case .waiting(let code) = phase else { return }
        copy(code.code)
        isCodeCopied = true
    }

    func copyCommand() {
        copy(commandText)
        isCommandCopied = true
    }

    // MARK: - Private

    private func show(_ code: GHDeviceCodeModel, run: Int) {
        guard run == generation, phase == .starting else { return }
        phase = .waiting(code)
    }

    private func end(_ run: Int, with outcome: Phase) {
        guard run == generation else { return }
        task = nil
        phase = outcome
        if outcome == .approved {
            didApprove()
        }
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        cancel()
    }
}
