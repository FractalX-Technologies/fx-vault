import SwiftUI
import VaultCore

/// Add file secret (1.0 F1; board Place-FileSheet), rules in ``FileSecretViewModel``. UI feature
/// contract entry view (ARCHITECTURE.md): presented by `MainScreen` for `MainSheet.fileSecret`,
/// from a place's ⋯ More and from a file dropped on it.
struct FileSecretScreen: View {
    @State private var viewModel: FileSecretViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    init(context: FileSecretContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: FileSecretViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        DialogSheet(title: FileSecretCopy.title, subtitle: viewModel.subtitle, isWorking: viewModel.isSaving) {
            switch viewModel.names.loadState {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            case .unavailable(let error):
                Banner(.danger, message: error.message)
            case .ready:
                FileSecretForm(viewModel: viewModel, isNameFocused: $isNameFocused)
            }
        } actions: {
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: close)
                .fxButtonStyle(.outline, size: .dialog)
                .keyboardShortcut(.cancelAction)
            Button(FileSecretCopy.add, action: save)
                .fxButtonStyle(.primary, size: .dialog)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canSave)
                .accessibilityIdentifier(AccessibilityID.FileSecret.add)
        }
        .frame(width: Theme.Layout.fileSecretSheetWidth)
        .task { await viewModel.load() }
        .onDisappear { viewModel.dropFile() }
        .errorAlert($viewModel.alert)
    }

    private func save() {
        if viewModel.save() {
            dismiss()
        }
    }

    private func close() {
        viewModel.dropFile()
        dismiss()
    }
}

/// The fields of a loaded sheet, in the board's order.
private struct FileSecretForm: View {
    @Bindable var viewModel: FileSecretViewModel
    var isNameFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var names = viewModel.names
        if let reason = names.readOnlyReason {
            Banner(.warning, message: reason.localizedExplanation, systemImage: "lock")
        }
        DialogStackedField(FileSecretCopy.name) {
            TextField(FileSecretCopy.name, text: $names.name, prompt: Text(verbatim: "APNS_KEY"))
                .focused(isNameFocused)
                .autocorrectionDisabled()
                .labelsHidden()
                .fxInputField(.dialog, isFocused: isNameFocused.wrappedValue, isInvalid: viewModel.nameNote?.isError ?? false, isMonospaced: true)
                .disabled(!viewModel.canEdit)
                .accessibilityIdentifier(AccessibilityID.FileSecret.name)
            ConfigEditorNoteView(note: viewModel.nameNote ?? .info(FileSecretCopy.nameHint), style: .dialog)
        }
        FileSecretFileRow(file: viewModel.file, isReading: viewModel.isReading, isEnabled: viewModel.canEdit) {
            if let url = FileSecretPanels.chooseFile() {
                Task { await viewModel.choose(url) }
            }
        }
        if let note = viewModel.fileNote {
            ConfigEditorNoteView(note: note, style: .dialog)
        }
        storeAsField
        if viewModel.removesTrailingLineBreaks {
            DialogNoteBox {
                DialogNote(systemImage: "exclamationmark.triangle", text: FileSecretCopy.trailingLineBreaks, tint: Theme.Colors.mutedText)
            }
        }
        Text(verbatim: viewModel.limitsLine)
            .fxTextStyle(.monoLabel)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AccessibilityID.FileSecret.limits)
    }

    private var storeAsField: some View {
        VStack(alignment: .trailing, spacing: Theme.Layout.dialogNoteSpacing) {
            HStack {
                Text(FileSecretCopy.storeAs)
                    .fxTextStyle(.formLabel)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .accessibilityHidden(true)
                Spacer(minLength: Theme.Spacing.medium)
                SegmentedPill(
                    selection: $viewModel.encoding,
                    segments: FileSecretEncoding.allCases.map { encoding in
                        .init(value: encoding, title: FileSecretCopy.encoding(encoding), isEnabled: encoding == .base64 || viewModel.isEncodingEditable)
                    },
                    accessibilityLabel: FileSecretCopy.storeAs,
                    size: .small
                )
                .disabled(!viewModel.canEdit)
            }
            Text(viewModel.encodingHint)
                .fxTextStyle(.formNote)
                .foregroundStyle(Theme.Colors.mutedText)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// The chosen file (board Place-FileSheet): its name in mono, its size and lines, then Choose….
private struct FileSecretFileRow: View {
    let file: FileSecretViewModel.FileModel?
    let isReading: Bool
    let isEnabled: Bool
    let onChoose: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "doc")
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityHidden(true)
            if let file {
                Text(verbatim: file.name)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: FileSecretCopy.fileFacts(file.facts))
                    .fxTextStyle(.formNote)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .layoutPriority(1)
            } else if isReading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(FileSecretCopy.noFile)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
            Spacer(minLength: Theme.Spacing.small)
            Button(FileSecretCopy.choose, action: onChoose)
                .fxButtonStyle(.ghost, size: .compact)
                .disabled(!isEnabled)
                .accessibilityIdentifier(AccessibilityID.FileSecret.choose)
        }
        .fxDialogListBox()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.FileSecret.file)
    }
}
