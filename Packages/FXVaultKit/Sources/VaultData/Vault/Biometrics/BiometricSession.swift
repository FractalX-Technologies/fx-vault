import Foundation
import LocalAuthentication

/// One Touch ID check that FX Vault shows in its own UI, the notch island's
/// `LAAuthenticationView` (1.0 B11e2). Its `LAContext` is evaluated once, then reads the DEK, so
/// one touch unlocks with no second system prompt. A lock invalidates it (§5.5).
public final class BiometricSession: @unchecked Sendable {
    // `LAContext` is thread-safe; the SDK doesn't mark it `Sendable`.
    /// For `LAAuthenticationView(context:)` only: ``BiometricKeyStoring`` evaluates it.
    public let context: LAContext

    init(context: LAContext) {
        self.context = context
    }
}
