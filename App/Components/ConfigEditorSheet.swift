import SwiftUI

/// The layout shared by the editor sheets of `ItemEditor/` and `Environment/` (§10 Sheets): a
/// header, a grouped form and a footer with Cancel (Esc) and the primary button (Return).
///
/// The primary button is the default action; destructive steps never sit behind it (they ask
/// through a confirmation whose default is Cancel).
struct ConfigEditorSheet<Content: View>: View {
    let title: String
    let subtitle: String?
    let primaryTitle: String
    let isPrimaryEnabled: Bool
    let isWorking: Bool
    let onCancel: () -> Void
    let onPrimary: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        primaryTitle: String,
        isPrimaryEnabled: Bool,
        isWorking: Bool,
        onCancel: @escaping () -> Void,
        onPrimary: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.primaryTitle = primaryTitle
        self.isPrimaryEnabled = isPrimaryEnabled
        self.isWorking = isWorking
        self.onCancel = onCancel
        self.onPrimary = onPrimary
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.xLarge)
            .padding(.top, Theme.Spacing.xLarge)

            Form {
                content()
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(primaryTitle, action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isPrimaryEnabled)
            }
            .padding(Theme.Spacing.large)
        }
        .frame(width: Theme.Layout.editorSheetWidth)
        .background(Theme.Colors.background)
    }
}

/// A one-line note under a field or in a form section: validation feedback, a warning or an
/// explanation. Never carries a value.
struct ConfigEditorNoteModel: Hashable {
    enum Tone: Hashable {
        case error
        case warning
        case info
        case success
    }

    let message: String
    let tone: Tone

    static func error(_ message: String) -> ConfigEditorNoteModel {
        ConfigEditorNoteModel(message: message, tone: .error)
    }

    static func warning(_ message: String) -> ConfigEditorNoteModel {
        ConfigEditorNoteModel(message: message, tone: .warning)
    }

    static func info(_ message: String) -> ConfigEditorNoteModel {
        ConfigEditorNoteModel(message: message, tone: .info)
    }

    static func success(_ message: String) -> ConfigEditorNoteModel {
        ConfigEditorNoteModel(message: message, tone: .success)
    }

    /// True when the note blocks the primary action.
    var isError: Bool {
        tone == .error
    }
}

/// Renders a ``ConfigEditorNoteModel`` with its icon and semantic color.
struct ConfigEditorNoteView: View {
    let note: ConfigEditorNoteModel

    var body: some View {
        Label {
            Text(note.message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(note.tone == .info ? Theme.Colors.textSecondary : Theme.Colors.textPrimary)
    }

    private var systemImage: String {
        switch note.tone {
        case .error: "exclamationmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch note.tone {
        case .error: Theme.Colors.danger
        case .warning: Theme.Colors.warning
        case .info: Theme.Colors.textSecondary
        case .success: Theme.Colors.success
        }
    }
}
