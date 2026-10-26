import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The global shortcut that opens the quick vault (board Settings-General; default ⌃⌥V).
/// Settings › General records it and ``PreferencesManager`` stores it; the quick vault registers
/// it as a Carbon hot key (``carbonKeyCode``, ``carbonModifiers``), which needs no
/// Accessibility permission.
struct QuickVaultShortcutModel: Hashable, Sendable {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
        static let all: Modifiers = [.control, .option, .shift, .command]

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        init(_ flags: NSEvent.ModifierFlags) {
            var modifiers: Modifiers = []
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.command) }
            self = modifiers
        }
    }

    /// The virtual key code (`kVK_*`): where the key sits, whatever the keyboard layout.
    let keyCode: UInt16
    let modifiers: Modifiers
    /// The key as it read when recorded ("V", "F5", "Space"), for display only.
    let key: String

    static let standard = QuickVaultShortcutModel(keyCode: UInt16(kVK_ANSI_V), modifiers: [.control, .option], key: "V")

    /// Key codes are 7-bit; a longer label is a hand-edited defaults file.
    static let maxKeyCode: UInt16 = 0x7F
    static let maxKeyLength = 8

    /// A recorded key press, or nil when it can't be a global shortcut: fewer than two modifiers
    /// or none of ⌃ ⌥ ⌘ (a hot key on ⌘X or ⇧X would take that key from every app), or a key
    /// with nothing to show.
    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, characters: String?) {
        let label = Self.specialKeys[Int(keyCode)] ?? characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let label else { return nil }
        self.init(keyCode: keyCode, modifiers: Modifiers(modifierFlags), key: label)
        guard isValid else { return nil }
    }

    init(keyCode: UInt16, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    var isValid: Bool {
        keyCode <= Self.maxKeyCode
            && !key.isEmpty && key.count <= Self.maxKeyLength
            && Modifiers.all.isSuperset(of: modifiers)
            && Self.isAllowed(modifiers)
    }

    static func isAllowed(_ modifiers: Modifiers) -> Bool {
        let count = [Modifiers.control, .option, .shift, .command].filter { modifiers.contains($0) }.count
        return count >= 2 && !modifiers.isDisjoint(with: [.control, .option, .command])
    }

    /// "⌃⌥V": the modifiers in the system's order, then the key.
    var displayText: String {
        Self.glyphs.filter { modifiers.contains($0.modifier) }.map(\.glyph).joined() + key
    }

    /// "Control-Option-V", for VoiceOver.
    var spokenText: String {
        (Self.glyphs.filter { modifiers.contains($0.modifier) }.map(\.name) + [key]).joined(separator: "-")
    }

    var carbonKeyCode: UInt32 {
        UInt32(keyCode)
    }

    /// The modifier mask `RegisterEventHotKey` takes.
    var carbonModifiers: UInt32 {
        var mask = 0
        if modifiers.contains(.control) { mask |= controlKey }
        if modifiers.contains(.option) { mask |= optionKey }
        if modifiers.contains(.shift) { mask |= shiftKey }
        if modifiers.contains(.command) { mask |= cmdKey }
        return UInt32(mask)
    }

    private static let glyphs: [(modifier: Modifiers, glyph: String, name: String)] = [
        (.control, "⌃", String(localized: "shortcut.control", defaultValue: "Control")),
        (.option, "⌥", String(localized: "shortcut.option", defaultValue: "Option")),
        (.shift, "⇧", String(localized: "shortcut.shift", defaultValue: "Shift")),
        (.command, "⌘", String(localized: "shortcut.command", defaultValue: "Command")),
    ]

    /// Keys whose characters say nothing (space, arrows, function keys).
    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

extension QuickVaultShortcutModel {
    /// The same keys as a menu item's shortcut (the menu bar's Quick Vault); nil for a key a
    /// menu can't show.
    var keyboardShortcut: KeyboardShortcut? {
        let key: KeyEquivalent? = if let special = Self.keyEquivalents[Int(keyCode)] {
            special
        } else if let function = Self.functionKeys.firstIndex(of: Int(keyCode)),
                  let scalar = UnicodeScalar(NSF1FunctionKey + function) {
            KeyEquivalent(Character(scalar))
        } else if self.key.count == 1, let character = self.key.lowercased().first {
            KeyEquivalent(character)
        } else {
            nil
        }
        guard let key else { return nil }
        var flags: SwiftUI.EventModifiers = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return KeyboardShortcut(key, modifiers: flags)
    }

    private static let keyEquivalents: [Int: KeyEquivalent] = [
        kVK_Space: .space, kVK_Return: .return, kVK_Tab: .tab, kVK_Delete: .delete, kVK_ForwardDelete: .deleteForward,
        kVK_LeftArrow: .leftArrow, kVK_RightArrow: .rightArrow, kVK_UpArrow: .upArrow, kVK_DownArrow: .downArrow,
        kVK_Home: .home, kVK_End: .end, kVK_PageUp: .pageUp, kVK_PageDown: .pageDown,
    ]

    /// F1 to F12, in order: their characters follow `NSF1FunctionKey`.
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]
}
