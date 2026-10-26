import Foundation
import Observation
import VaultCore
import VaultData

/// Copy All's steps: "Confirm it's you", then what was copied.
enum CopyAllStep: Equatable {
    case authenticate
    case done(count: Int)
}

/// Copy All (1.0 D6c4; brief "Copy All (Touch ID)"): `ReauthGate` first, then every live value
/// of the place as `.env` text through `ClipboardManager` (concealed, cleared after 30 s, on lock
/// and on quit). The text exists only between `EnvFileRepository` and the clipboard; nothing is
/// logged.
@Observable
final class CopyAllViewModel: LockObserving {
    let place: ItemHolderModel
    let reauth: ReauthModel<EnvExportAuthorizationModel>
    private(set) var step: CopyAllStep = .authenticate
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let dependencies: FeatureDependencies

    init(context: CopyAllContext, dependencies: FeatureDependencies) {
        place = context.place
        self.dependencies = dependencies
        let gate = dependencies.reauth
        let session = dependencies.session
        reauth = ReauthModel(
            prompt: FeatureDependencies.reauthPrompt(for: .copyAll),
            touchIDStatus: dependencies.touchIDStatus()
        ) { credential in
            try await gate.authorizeEnvExport(.clipboard, with: credential, session: session)
        }
        dependencies.actions.addLockObserver(self)
    }

    /// The clipboard's clear delay, for the done step.
    var clearSeconds: Int {
        dependencies.clipboard.clearDelay.wholeSeconds
    }

    /// Tries Touch ID once when the sheet appears; a Mac without it shows the password field.
    func start() async {
        await authenticateWithTouchID(automatic: true)
    }

    func authenticateWithTouchID(automatic: Bool = false) async {
        guard step == .authenticate else { return }
        if await reauth.authorizeWithTouchID(automatic: automatic) {
            copy()
        }
    }

    func authenticateWithPassword() async {
        guard step == .authenticate else { return }
        if await reauth.authorizeWithPassword() {
            copy()
        }
    }

    /// Drops the typed password and an unused authorization. Call it when the sheet closes.
    func close() {
        reauth.reset()
    }

    func vaultDidLock() {
        reauth.reset()
        step = .authenticate
    }

    /// Consumes the authorization: a failure needs a new check.
    private func copy() {
        guard let authorization = reauth.takeAuthorization() else { return }
        do {
            let copied = try dependencies.envFiles.copyAllText(of: place, authorization: authorization) { kind, count in
                CopyAllCopy.section(kind, count: count)
            }
            try dependencies.copy(copied.text)
            step = .done(count: copied.valueCount)
        } catch {
            alert = error.presentation
        }
    }
}
