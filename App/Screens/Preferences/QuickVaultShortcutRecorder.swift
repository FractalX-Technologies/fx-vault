import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The quick vault shortcut box (board Settings-General): click it, then press the new shortcut.
/// Esc cancels; a key the model refuses (``QuickVaultShortcutModel/init(keyCode:modifierFlags:characters:)``)
/// beeps and keeps listening.
struct QuickVaultShortcutRecorder: View {
    let title: String
    @Binding var shortcut: QuickVaultShortcutModel
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            Text(verbatim: isRecording ? prompt : shortcut.displayText)
                .font(isRecording ? Theme.Typography.caption : Theme.Typography.body)
                .foregroundStyle(isRecording ? Theme.Colors.subtleText : Theme.Colors.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .dialogFieldChrome(border: isRecording ? Theme.Colors.ink : Theme.Colors.hairlineStrong)
        .help(String(
            localized: "settings.general.quickVault.help",
            defaultValue: "Click, then press the new shortcut. Use at least two of Control, Option, Shift and Command. Esc cancels."
        ))
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: isRecording ? prompt : shortcut.spokenText))
        // A local monitor sees every key of the app: never leave it running once the user is
        // elsewhere, or it would swallow the main window's typing.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var prompt: String {
        String(localized: "settings.general.quickVault.recording", defaultValue: "Type shortcut")
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        guard let recorded = QuickVaultShortcutModel(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            characters: event.characters(byApplyingModifiers: [])
        ) else {
            NSSound.beep()
            return
        }
        shortcut = recorded
        stopRecording()
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}

#Preview {
    QuickVaultShortcutRecorder(title: "Quick vault shortcut", shortcut: .constant(.standard))
        .frame(width: Theme.Layout.settingsPopUpWidth)
        .padding()
}
