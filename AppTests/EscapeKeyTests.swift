import AppKit
import Carbon.HIToolbox
import Testing
@testable import FXVault

/// ``EscapeKey``: which key-down closes the ⌘K palette. Caps Lock and an input method's
/// composition are the cases the UI test cannot reach.
@MainActor
@Suite("Escape key")
struct EscapeKeyTests {
    private let escape = UInt16(kVK_Escape)

    private func runsAction(
        keyCode: UInt16? = nil,
        flags: NSEvent.ModifierFlags = [],
        hasMarkedText: Bool = false,
        isWatchedWindow: Bool = true
    ) -> Bool {
        EscapeKey.runsAction(
            keyCode: keyCode ?? escape,
            flags: flags,
            hasMarkedText: hasMarkedText,
            isWatchedWindow: isWatchedWindow
        )
    }

    @Test func aPlainEscRunsIt() {
        #expect(runsAction())
    }

    /// Caps Lock, fn, the keypad and help are states of the keyboard, not modifiers.
    @Test func escWithCapsLockOrFnStillRunsIt() {
        let states: [NSEvent.ModifierFlags] = [.capsLock, .function, .numericPad, .help, [.capsLock, .function]]
        for flags in states {
            #expect(runsAction(flags: flags), "flags \(flags.rawValue)")
        }
    }

    @Test func aModifiedEscOrAnotherKeyIsLeftAlone() {
        let modifiers: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift, [.capsLock, .shift]]
        for flags in modifiers {
            #expect(!runsAction(flags: flags), "flags \(flags.rawValue)")
        }
        #expect(!runsAction(keyCode: UInt16(kVK_Return)))
    }

    /// Esc that ends an input method's composition (Japanese, Chinese) belongs to the field.
    @Test func escEndingACompositionIsLeftToTheField() {
        #expect(!runsAction(hasMarkedText: true))
        #expect(!runsAction(flags: .capsLock, hasMarkedText: true))
    }

    @Test func escInAnotherWindowIsLeftAlone() {
        #expect(!runsAction(isWatchedWindow: false))
    }
}
