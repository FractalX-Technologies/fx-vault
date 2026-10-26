import AppKit
import SwiftUI
import Testing
@testable import FXVault

/// v0.3.0 sheet restyle (board SyncReview): the pure presentation rules of the Sync footer, the
/// drift banner, the value editor frame and editor notes, and the sizing of the scrolling editor
/// sheet.
@MainActor
@Suite("Sheet presentation")
struct SheetPresentationTests {
    // MARK: - Sync footer

    @Test func syncFooterMapsButtonsToPills() {
        let cancel = SyncButtonModel(action: .close, title: "Cancel", isCancel: true)
        let sync = SyncButtonModel(action: .sync, title: "Sync 3", isDefault: true)
        let back = SyncButtonModel(action: .back, title: "Back", isCancel: true)
        let withoutDeleting = SyncButtonModel(action: .syncWithoutDeleting, title: "Sync Without Deleting")
        let delete = SyncButtonModel(action: .confirmDeletions, title: "Delete 2 Items on GitHub", isDestructive: true)
        let cancelRun = SyncButtonModel(action: .cancelRun, title: "Cancel")

        #expect(SyncFooterView.variant(for: cancel) == .secondary)
        #expect(SyncFooterView.variant(for: sync) == .primary)
        #expect(SyncFooterView.variant(for: back) == .secondary)
        #expect(SyncFooterView.variant(for: withoutDeleting) == .outline)
        #expect(SyncFooterView.variant(for: delete) == .destructive)
        #expect(SyncFooterView.variant(for: cancelRun) == .secondary)
    }

    @Test func syncFooterKeepsTheDefaultAndCancelBindings() {
        #expect(SyncFooterView.shortcut(for: SyncButtonModel(action: .sync, title: "Sync", isDefault: true)) == .defaultAction)
        #expect(SyncFooterView.shortcut(for: SyncButtonModel(action: .close, title: "Cancel", isCancel: true)) == .cancelAction)
        // §7.5: the deletion buttons are neither the default nor bound to Escape.
        let delete = SyncButtonModel(action: .confirmDeletions, title: "Delete", isDestructive: true)
        #expect(SyncFooterView.shortcut(for: delete) == nil)
        #expect(SyncFooterView.shortcut(for: SyncButtonModel(action: .syncWithoutDeleting, title: "Sync")) == nil)
    }

    // MARK: - Drift line

    @Test func driftLineSaysWhatChangedAndWarnsOnConflicts() {
        #expect(DriftBannerView.tone(conflictCount: 0) == .info)
        #expect(DriftBannerView.tone(conflictCount: 1) == .warning)
        #expect(DriftBannerView.message(count: 3, conflictCount: 0) == "3 changed on GitHub")
        let withConflicts = DriftBannerView.message(count: 3, conflictCount: 1)
        #expect(withConflicts.hasPrefix("3 changed on GitHub"))
        #expect(withConflicts.hasSuffix(DriftCopy.bannerConflicts(1)))
    }

    // MARK: - Value editor and notes

    @Test func valueEditorIsFramedLikeARoundedInput() {
        #expect(SecretValueEditor.borderColor(isFocused: false) == Theme.Colors.hairlineStrong)
        #expect(SecretValueEditor.borderWidth(isFocused: false) == Theme.Stroke.hairline)
        #expect(SecretValueEditor.borderColor(isFocused: true) == Theme.Colors.brand)
        #expect(SecretValueEditor.borderWidth(isFocused: true) == Theme.Layout.focusRingWidth)
    }

    @Test func editorNotesUseSemanticTones() {
        #expect(ConfigEditorNoteView.tint(for: .error) == Theme.Colors.danger)
        #expect(ConfigEditorNoteView.tint(for: .warning) == Theme.Colors.warning)
        #expect(ConfigEditorNoteView.tint(for: .success) == Theme.Colors.success)
        #expect(ConfigEditorNoteView.textColor(for: .info) == Theme.Colors.mutedText)
        #expect(ConfigEditorNoteView.textColor(for: .error) == Theme.Colors.ink)
    }

    // MARK: - Sizing

    /// The editor sheets scroll their fields; a system sheet takes the hosting view's fitting
    /// size, so the scroll view must report its content height instead of collapsing.
    @Test func editorSheetSizesToItsContent() {
        let short = NSHostingView(rootView: Self.sheet(fieldCount: 1))
        let tall = NSHostingView(rootView: Self.sheet(fieldCount: 4))
        #expect(short.fittingSize.width == Theme.Layout.editorSheetWidth)
        #expect(short.fittingSize.height > Theme.Layout.inputHeight + Theme.Layout.buttonHeightLarge + Theme.Spacing.xxLarge * 2)
        #expect(tall.fittingSize.height > short.fittingSize.height + Theme.Layout.inputHeight * 3)
    }

    private static func sheet(fieldCount: Int) -> some View {
        ConfigEditorSheet(
            eyebrow: "Environment",
            title: "New Environment",
            subtitle: "In owner-a/fx-vault",
            primaryTitle: "Create",
            isPrimaryEnabled: true,
            isWorking: false,
            onCancel: {},
            onPrimary: {}
        ) {
            ForEach(0..<fieldCount, id: \.self) { index in
                ConfigSheetField("Field \(index)") {
                    FXTextField(label: nil, text: .constant("staging"), isMonospaced: true)
                }
            }
        }
    }
}
