import Observation
import VaultCore
import VaultCrypto
import VaultData

/// Onboarding (§10.1): Welcome → Create password → Recovery key → Confirm 2 groups → Touch ID
/// (signed builds only). The last step opens the Connect phase (``ConnectScreen``).
///
/// The vault is created when the password step completes, so the recovery key can be shown. If
/// the vault locks before the key is confirmed, the key is wiped and
/// `PreferencesManager.isRecoveryKeyConfirmationPending` stays set, so the main window asks the
/// user to create a new one.
@Observable
final class OnboardingViewModel: LockObserving {
    enum Step: Int, CaseIterable, Comparable {
        case welcome
        case createPassword
        case recoveryKey
        case confirmRecoveryKey
        case touchID

        static func < (lhs: Step, rhs: Step) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Picks which recovery key groups the user re-enters (`count` distinct indices in
    /// `0..<groupCount`, sorted). Injected so tests are deterministic.
    typealias GroupPicker = (_ groupCount: Int, _ count: Int) -> [Int]

    static let randomGroupPicker: GroupPicker = { groupCount, count in
        Array((0..<groupCount).shuffled().prefix(count)).sorted()
    }

    private(set) var step: Step = .welcome

    var password = "" {
        didSet {
            strength = PasswordStrength.evaluate(password)
            if password != generatedPassphrase {
                generatedPassphrase = nil
            }
        }
    }
    var passwordConfirmation = ""
    private(set) var strength = PasswordStrength.evaluate("")
    /// The last generated passphrase, shown word by word until the password changes.
    private(set) var generatedPassphrase: String?

    private(set) var isWorking = false
    private(set) var error: ErrorPresentationModel?

    /// The recovery key groups while the key is on screen; empty otherwise.
    private(set) var recoveryKeyGroups: [String] = []
    private(set) var hasCopiedRecoveryKey = false
    /// "I saved it offline" (1.0): Continue waits for it, so the key is not skipped by habit.
    var hasSavedRecoveryKey = false
    /// 0-based indices of the groups to confirm.
    private(set) var confirmationIndices: [Int] = []
    var confirmationInputs: [String] = []
    private(set) var confirmationFailed = false

    private(set) var isTouchIDEnabled = false

    /// Whether the Touch ID step is part of this onboarding (signed builds only, D14).
    let includesTouchIDStep: Bool
    /// Why Touch ID cannot be enabled on this Mac (signed build, but no sensor or no
    /// fingerprints), or nil.
    let touchIDUnavailableReason: BiometryUnavailableReason?

    @ObservationIgnored private let app: AppViewModel
    @ObservationIgnored private let groupPicker: GroupPicker
    @ObservationIgnored private var recoveryKey: RecoveryKey?

    init(app: AppViewModel, groupPicker: @escaping GroupPicker = OnboardingViewModel.randomGroupPicker) {
        self.app = app
        self.groupPicker = groupPicker
        let availability = app.container.vaultManager.biometricsAvailability()
        includesTouchIDStep = availability != .unsignedBuild
        touchIDUnavailableReason = availability
        app.addLockObserver(self)
    }

    /// The steps shown in the progress indicator.
    var visibleSteps: [Step] {
        Step.allCases.filter { $0 != .touchID || includesTouchIDStep }
    }

    /// The Secure phase (1.0, "Secure · Connect · Import"): password, recovery key, confirm and,
    /// when offered, Touch ID.
    var secureSteps: [Step] {
        visibleSteps.filter { $0 != .welcome }
    }

    /// The current step's number in the Secure phase (`01 / 04`), or nil on Welcome.
    var secureStepNumber: Int? {
        secureSteps.firstIndex(of: step).map { $0 + 1 }
    }

    // MARK: - Welcome

    func start() {
        step = .createPassword
    }

    // MARK: - Create password

    /// Back to Welcome; nothing typed is kept.
    func backToWelcome() {
        guard step == .createPassword, !isWorking else { return }
        clearPasswords()
        error = nil
        step = .welcome
    }

    var passwordsMatch: Bool {
        !passwordConfirmation.isEmpty && password == passwordConfirmation
    }

    var showsMismatch: Bool {
        !passwordConfirmation.isEmpty && password != passwordConfirmation
    }

    var canCreateVault: Bool {
        strength.isAcceptable && passwordsMatch && !isWorking
    }

    var canGeneratePassphrase: Bool {
        app.container.passphraseGenerator != nil
    }

    /// Fills both fields with a new 6-word passphrase (D8).
    func generatePassphrase() {
        guard let generator = app.container.passphraseGenerator else { return }
        let bytes = generator.generate()
        defer { bytes.wipe() }
        guard let passphrase = bytes.utf8String() else { return }
        password = passphrase
        passwordConfirmation = passphrase
        generatedPassphrase = passphrase
    }

    /// Copies the generated passphrase (concealed, cleared after 30 s).
    func copyGeneratedPassphrase() {
        guard let generatedPassphrase else { return }
        app.container.clipboard.copy(generatedPassphrase)
    }

    /// Creates the vault (Argon2id runs off the main actor) and shows the recovery key.
    func createVault() async {
        guard canCreateVault else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let key = try await app.container.vaultManager.create(password: password)
            guard step == .createPassword else {
                // Locked or reset while the KDF ran.
                key.wipe()
                return
            }
            recoveryKey = key
            recoveryKeyGroups = key.groups
            app.container.preferences.isRecoveryKeyConfirmationPending = true
            step = .recoveryKey
        } catch {
            self.error = error.presentation
        }
    }

    // MARK: - Recovery key

    /// Copies the formatted key through the clipboard manager (concealed, cleared after 30 s).
    func copyRecoveryKey() {
        guard let recoveryKey else { return }
        app.container.clipboard.copy(recoveryKey.formatted)
        hasCopiedRecoveryKey = true
    }

    var canContinueFromRecoveryKey: Bool {
        recoveryKey != nil && hasSavedRecoveryKey
    }

    /// Continue after "I saved it offline": asks for 2 random groups.
    func continueToConfirmation() {
        guard canContinueFromRecoveryKey else { return }
        confirmationIndices = groupPicker(recoveryKeyGroups.count, Limits.recoveryConfirmGroupCount)
        confirmationInputs = Array(repeating: "", count: confirmationIndices.count)
        confirmationFailed = false
        step = .confirmRecoveryKey
    }

    // MARK: - Confirm

    var canConfirmRecoveryKey: Bool {
        !confirmationIndices.isEmpty
            && confirmationInputs.count == confirmationIndices.count
            && confirmationInputs.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func backToRecoveryKey() {
        confirmationFailed = false
        step = .recoveryKey
    }

    /// Checks the entered groups; on success the key is wiped and never shown again.
    func confirmRecoveryKey() {
        guard let recoveryKey, canConfirmRecoveryKey else { return }
        let allMatch = zip(confirmationIndices, confirmationInputs).allSatisfy { index, input in
            recoveryKey.matches(group: input, at: index)
        }
        confirmationFailed = !allMatch
        guard allMatch else { return }
        wipeRecoveryKey()
        app.container.preferences.isRecoveryKeyConfirmationPending = false
        if includesTouchIDStep {
            step = .touchID
        } else {
            finish()
        }
    }

    // MARK: - Touch ID

    var canEnableTouchID: Bool {
        includesTouchIDStep && touchIDUnavailableReason == nil && !isWorking
    }

    /// Stores the DEK in the Touch ID keychain item (signed builds, §5.5).
    func enableTouchID() async {
        guard canEnableTouchID else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await app.container.vaultManager.enableBiometrics(password: password)
            isTouchIDEnabled = true
            finish()
        } catch {
            if !error.isCancellation {
                self.error = error.presentation
            }
        }
    }

    func skipTouchID() {
        finish()
    }

    /// Leaves onboarding for the Connect phase; the vault is unlocked.
    private func finish() {
        clearPasswords()
        app.completeOnboarding()
    }

    // MARK: - Lock

    func vaultDidLock() {
        wipeRecoveryKey()
        clearPasswords()
        confirmationInputs = []
        confirmationIndices = []
        isWorking = false
        error = nil
        step = .welcome
    }

    // MARK: - Private

    private func wipeRecoveryKey() {
        recoveryKey?.wipe()
        recoveryKey = nil
        recoveryKeyGroups = []
        hasCopiedRecoveryKey = false
        hasSavedRecoveryKey = false
    }

    private func clearPasswords() {
        password = ""
        passwordConfirmation = ""
        generatedPassphrase = nil
    }
}
