import Foundation
import ServiceManagement

/// Whether FX Vault opens at login, as System Settings › General › Login Items has it.
enum LoginItemStatus: Equatable {
    case off
    case on
    /// Registered, but the user has to allow it in System Settings first.
    case needsApproval
}

/// Open at login (Settings › General). The system is the only record: nothing is stored in
/// preferences, so turning it off in System Settings shows here too.
protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// ``LoginItemControlling`` over `SMAppService.mainApp` (macOS 13+).
final class LoginItemManager: LoginItemControlling {
    private let service = SMAppService.mainApp

    var status: LoginItemStatus {
        switch service.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered, .notFound: .off
        @unknown default: .off
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Records Open at login instead of registering the app (previews, tests, UI tests).
final class RecordedLoginItem: LoginItemControlling {
    private(set) var status: LoginItemStatus = .off
    /// The status the next ``register()`` reaches (the system may ask for approval).
    var statusAfterRegister: LoginItemStatus = .on
    /// Thrown by the next ``register()`` or ``unregister()``.
    var failure: (any Error)?
    private(set) var openedSystemSettings = false

    func register() throws {
        if let failure { throw failure }
        status = statusAfterRegister
    }

    func unregister() throws {
        if let failure { throw failure }
        status = .off
    }

    func openSystemSettings() {
        openedSystemSettings = true
    }
}
