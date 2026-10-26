import Carbon.HIToolbox
import Foundation

/// The quick vault's global shortcut (1.0 Q1): registered with macOS so it works from any app.
/// Carbon live (``CarbonQuickVaultHotKey``, no Accessibility permission needed); recorded in
/// previews, tests and the UI-testing build, which must never take a key from the developer.
protocol QuickVaultHotKeyRegistering: AnyObject {
    /// Registers `shortcut` in place of any earlier one; false when macOS refuses it (another
    /// app holds the same keys).
    @discardableResult
    func register(_ shortcut: QuickVaultShortcutModel, onPress: @escaping () -> Void) -> Bool
    func unregister()
}

/// `RegisterEventHotKey` on the application event target. One shortcut at a time.
final class CarbonQuickVaultHotKey: QuickVaultHotKeyRegistering {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onPress: (() -> Void)?

    /// "FXVQ": tells our hot key apart in the event.
    private static let signature: OSType = 0x4658_5651

    @discardableResult
    func register(_ shortcut: QuickVaultShortcutModel, onPress: @escaping () -> Void) -> Bool {
        unregister()
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.carbonKeyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            AppLog.ui.error("Quick vault shortcut was not registered")
            return false
        }
        hotKey = ref
        self.onPress = onPress
        return true
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        hotKey = nil
        onPress = nil
    }

    fileprivate func pressed() {
        onPress?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            quickVaultHotKeyPressed,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    // The handler holds an unretained pointer to self: it must go first.
    isolated deinit {
        unregister()
        if let handler {
            RemoveEventHandler(handler)
        }
    }
}

/// Carbon's C callback. Hot keys arrive on the main thread's event loop.
private nonisolated func quickVaultHotKeyPressed(
    _ call: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context else { return OSStatus(eventNotHandledErr) }
    let address = UInt(bitPattern: context)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<CarbonQuickVaultHotKey>.fromOpaque(pointer).takeUnretainedValue().pressed()
    }
    return noErr
}

/// Registers nothing with macOS; keeps the shortcut so tests can check it and press it.
final class RecordedQuickVaultHotKey: QuickVaultHotKeyRegistering {
    private(set) var registered: QuickVaultShortcutModel?
    private(set) var registrationCount = 0
    private var onPress: (() -> Void)?

    @discardableResult
    func register(_ shortcut: QuickVaultShortcutModel, onPress: @escaping () -> Void) -> Bool {
        registered = shortcut
        registrationCount += 1
        self.onPress = onPress
        return true
    }

    func unregister() {
        registered = nil
        onPress = nil
    }

    /// The user pressed the shortcut (only while it is registered).
    func press() {
        onPress?()
    }
}
