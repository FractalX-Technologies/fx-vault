import AppKit
import Carbon.HIToolbox
import Testing
@testable import FXVault

/// Settings › General's quick vault shortcut (board Settings-General): what can be recorded, how
/// it is stored, and what the quick vault registers.
@MainActor
@Suite("QuickVaultShortcut")
struct QuickVaultShortcutTests {
    @Test func theDefaultIsControlOptionV() {
        let shortcut = PreferencesManager(store: InMemoryPreferencesStore()).quickVaultShortcut
        #expect(shortcut == .standard)
        #expect(shortcut.displayText == "⌃⌥V")
        #expect(shortcut.spokenText == "Control-Option-V")
        #expect(shortcut.carbonKeyCode == UInt32(kVK_ANSI_V))
        #expect(shortcut.carbonModifiers == UInt32(controlKey | optionKey))
    }

    @Test func aRecordedShortcutIsKeptAcrossLaunches() throws {
        let store = InMemoryPreferencesStore()
        let recorded = try #require(
            QuickVaultShortcutModel(keyCode: UInt16(kVK_ANSI_K), modifierFlags: [.command, .shift], characters: "k")
        )
        PreferencesManager(store: store).quickVaultShortcut = recorded

        let reloaded = PreferencesManager(store: store).quickVaultShortcut
        #expect(reloaded == recorded)
        #expect(reloaded.displayText == "⇧⌘K")
        #expect(reloaded.carbonKeyCode == UInt32(kVK_ANSI_K))
        #expect(reloaded.carbonModifiers == UInt32(cmdKey | shiftKey))
    }

    /// A hot key on ⌘X or ⇧X would take that key from every app.
    @Test func aGlobalShortcutNeedsTwoModifiersOneOfThemControlOptionOrCommand() {
        let refused: [NSEvent.ModifierFlags] = [[], [.command], [.shift], [.option], [.shift, .capsLock]]
        for flags in refused {
            #expect(QuickVaultShortcutModel(keyCode: UInt16(kVK_ANSI_V), modifierFlags: flags, characters: "v") == nil)
        }
        let accepted: [NSEvent.ModifierFlags] = [[.control, .option], [.command, .shift], [.control, .option, .shift, .command]]
        for flags in accepted {
            #expect(QuickVaultShortcutModel(keyCode: UInt16(kVK_ANSI_V), modifierFlags: flags, characters: "v") != nil)
        }
    }

    @Test func keysWithoutCharactersReadByName() throws {
        let f5 = try #require(QuickVaultShortcutModel(keyCode: UInt16(kVK_F5), modifierFlags: [.control, .option], characters: "\u{F708}"))
        #expect(f5.displayText == "⌃⌥F5")
        let space = try #require(QuickVaultShortcutModel(keyCode: UInt16(kVK_Space), modifierFlags: [.control, .option], characters: " "))
        #expect(space.displayText == "⌃⌥Space")
        #expect(space.spokenText == "Control-Option-Space")
        #expect(QuickVaultShortcutModel(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.control, .option], characters: " ") == nil)
    }

    @Test func aHandEditedShortcutReadsAsTheDefault() {
        let cases: [(keyCode: Int?, modifiers: Int?, key: String?)] = [
            (9, QuickVaultShortcutModel.Modifiers.command.rawValue, "V"),
            (300, QuickVaultShortcutModel.Modifiers([.control, .option]).rawValue, "V"),
            (9, 1 << 6 | QuickVaultShortcutModel.Modifiers([.control, .option]).rawValue, "V"),
            (9, QuickVaultShortcutModel.Modifiers([.control, .option]).rawValue, ""),
            (9, QuickVaultShortcutModel.Modifiers([.control, .option]).rawValue, "VVVVVVVVV"),
            (nil, QuickVaultShortcutModel.Modifiers([.control, .option]).rawValue, "V"),
        ]
        for entry in cases {
            let store = InMemoryPreferencesStore()
            if let keyCode = entry.keyCode {
                store.set(keyCode, forKey: PreferencesManager.Key.quickVaultKeyCode)
            }
            store.set(entry.modifiers ?? 0, forKey: PreferencesManager.Key.quickVaultModifiers)
            store.set(entry.key, forKey: PreferencesManager.Key.quickVaultKey)
            #expect(PreferencesManager(store: store).quickVaultShortcut == .standard)
        }
    }

    @Test func anInvalidShortcutIsNeverStored() {
        let store = InMemoryPreferencesStore()
        let preferences = PreferencesManager(store: store)
        preferences.quickVaultShortcut = QuickVaultShortcutModel(keyCode: UInt16(kVK_ANSI_V), modifiers: .command, key: "V")
        #expect(preferences.quickVaultShortcut == .standard)
        #expect(PreferencesManager(store: store).quickVaultShortcut == .standard)
    }
}
