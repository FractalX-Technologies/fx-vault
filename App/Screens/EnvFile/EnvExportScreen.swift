import AppKit
import EnvTools
import SwiftUI
import VaultData

/// EnvExportScreen (board Main2-Export): ReauthGate → warnings → save panel → gitignore offer,
/// each step in the 1.0 dialog. UI feature contract entry view (ARCHITECTURE.md): presented by
/// `MainScreen` for `MainSheet`. The init signature is fixed; the feature owns everything else
/// in this folder. Dismiss with `@Environment(\.dismiss)`.
struct EnvExportScreen: View {
    @State private var viewModel: EnvExportViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: EnvExportContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: EnvExportViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        EnvExportDialog(viewModel: viewModel, dismiss: { dismiss() })
            .errorAlert($viewModel.alert)
            .onDisappear { viewModel.discard() }
    }
}

/// The dialog itself, apart from the entry view's state so the snapshot renders a view model in
/// any step.
struct EnvExportDialog: View {
    let viewModel: EnvExportViewModel
    let dismiss: () -> Void

    var body: some View {
        DialogSheet(
            title: title,
            footerNote: String(localized: "envExport.footer", defaultValue: "Saved readable only by you. Delete it when you’re done."),
            isWorking: viewModel.isWorking
        ) {
            content
        } actions: {
            actions
        }
        .frame(width: Theme.Layout.envExportSheetWidth)
    }

    /// "Export api-service › production as .env".
    private var title: String {
        let place = viewModel.placeTitle
        if place.isEmpty {
            return String(localized: "envExport.title", defaultValue: "Export .env")
        }
        return String(localized: "envExport.title.place", defaultValue: "Export \(place) as .env")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .authenticate:
            EnvExportAuthenticateView(viewModel: viewModel)
        case .review:
            EnvExportReviewView(viewModel: viewModel)
        case .confirmCloudSync(let choice):
            EnvExportCloudWarningView(choice: choice)
        case .done(let outcome):
            EnvExportDoneView(viewModel: viewModel, outcome: outcome)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch viewModel.step {
        case .authenticate:
            cancelButton
            Button(String(localized: "envExport.auth.continue", defaultValue: "Continue")) {
                Task { await viewModel.authenticateWithPassword() }
            }
            .disabled(!viewModel.canAuthenticateWithPassword)
            .modifier(DefaultActionModifier(isDefault: viewModel.defaultAction == .password))
            if viewModel.showsTouchIDButton {
                Button {
                    Task { await viewModel.authenticateWithTouchID() }
                } label: {
                    Label(String(localized: "envExport.auth.touchID", defaultValue: "Use Touch ID"), systemImage: "touchid")
                }
                .disabled(!viewModel.canAuthenticateWithTouchID)
                .modifier(DefaultActionModifier(isDefault: viewModel.defaultAction == .touchID))
            }
        case .review:
            cancelButton
            Button(String(localized: "envExport.chooseLocation", defaultValue: "Choose Location…"), action: chooseLocation)
                .disabled(viewModel.isWorking)
                .modifier(DefaultActionModifier(isDefault: true))
        case .confirmCloudSync:
            cancelButton
            Button(String(localized: "envExport.cloud.exportAnyway", defaultValue: "Export Anyway")) {
                Task { await viewModel.confirmCloudSyncExport() }
            }
            .disabled(viewModel.isWorking)
            .modifier(DefaultActionModifier(isDefault: false))
            Button(String(localized: "envExport.cloud.chooseAnother", defaultValue: "Choose Another Location")) {
                viewModel.chooseAnotherLocation()
                chooseLocation()
            }
            .disabled(viewModel.isWorking)
            .modifier(DefaultActionModifier(isDefault: true))
        case .done:
            // With the `.gitignore` offer, Return adds the line (the button beside its note).
            if viewModel.defaultAction == .addToGitignore {
                Button(String(localized: "envExport.gitignore.notNow", defaultValue: "Not Now"), action: dismiss)
                    .fxButtonStyle(.outline, size: .dialog)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(String(localized: "common.done", defaultValue: "Done"), action: dismiss)
                    .modifier(DefaultActionModifier(isDefault: true))
            }
        }
    }

    private var cancelButton: some View {
        Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: dismiss)
            .fxButtonStyle(.outline, size: .dialog)
            .keyboardShortcut(.cancelAction)
    }

    private func chooseLocation() {
        guard let url = EnvFilePanels.chooseExportDestination(
            fileName: viewModel.suggestedFileName,
            directory: viewModel.suggestedDirectory
        ) else { return }
        Task { await viewModel.chooseDestination(url) }
    }
}

/// Makes a button the black Return pill when `isDefault`; otherwise the outline (board
/// Main2-Export).
private struct DefaultActionModifier: ViewModifier {
    let isDefault: Bool

    func body(content: Content) -> some View {
        if isDefault {
            content
                .fxButtonStyle(.primary, size: .dialog)
                .keyboardShortcut(.defaultAction)
        } else {
            content
                .fxButtonStyle(.outline, size: .dialog)
        }
    }
}

/// Step 1: Touch ID or the master password (ReauthGate, D30).
private struct EnvExportAuthenticateView: View {
    @Bindable var viewModel: EnvExportViewModel
    @FocusState private var isPasswordFocused: Bool

    private var passwordLabel: String {
        String(localized: "envExport.auth.password", defaultValue: "Master password")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumPlus) {
            if viewModel.preview == nil {
                ProgressView()
                    .controlSize(.small)
            } else if !viewModel.hasSomethingToExport {
                EnvExportSentence(text: String(
                    localized: "envExport.nothing",
                    defaultValue: "This scope has no values to export. Secrets without a value in FX Vault are never exported."
                ))
            } else {
                EnvExportSentence(text: String(
                    localized: "envExport.auth.message",
                    defaultValue: "Exporting writes \(viewModel.exportedCount) values to a file in plaintext. Confirm it's you with Touch ID or your master password."
                ))
                DialogStackedField(passwordLabel) {
                    SecureField(passwordLabel, text: $viewModel.password)
                        .focused($isPasswordFocused)
                        .fxInputField(.dialog, isFocused: isPasswordFocused, isInvalid: viewModel.authError != nil, isMonospaced: true)
                        .onSubmit { Task { await viewModel.authenticateWithPassword() } }
                }
                if let notice = viewModel.touchIDNotice {
                    Text(verbatim: notice)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                }
                if let error = viewModel.authError {
                    InlineErrorView(error: error)
                }
            }
        }
        .onChange(of: viewModel.passwordFocusRequest) {
            isPasswordFocused = true
        }
    }
}

/// Step 2: the plaintext warning and what is left out, in the bordered note box.
private struct EnvExportReviewView: View {
    let viewModel: EnvExportViewModel

    var body: some View {
        DialogNoteBox {
            DialogNote(
                systemImage: "exclamationmark.triangle",
                text: String(
                    localized: "envExport.warning.plaintext",
                    defaultValue: "The file will contain \(viewModel.exportedCount) values in plaintext. Anyone who can read the file can read them. Keep it out of git, synced folders and chats, and delete it when you are done."
                )
            )
            if !viewModel.valueMissingNames.isEmpty {
                EnvExportNameList(
                    title: String(
                        localized: "envExport.skipped.valueMissing",
                        defaultValue: "Skipped: \(viewModel.valueMissingNames.count) secrets have no value in FX Vault"
                    ),
                    names: viewModel.valueMissingNames
                )
            }
            if !viewModel.nameCollisions.isEmpty {
                EnvExportNameList(
                    title: String(
                        localized: "envExport.skipped.collisions",
                        defaultValue: "Skipped: \(viewModel.nameCollisions.count) variables share a name with an exported secret"
                    ),
                    names: viewModel.nameCollisions
                )
            }
            if !viewModel.unverifiedShareNames.isEmpty {
                EnvExportNameList(
                    title: String(
                        localized: "envExport.unverifiedShare",
                        defaultValue: "\(viewModel.unverifiedShareNames.count) values came from a share and are not verified on GitHub yet"
                    ),
                    names: viewModel.unverifiedShareNames
                )
            }
        }
    }
}

/// Step 3 (only for synced folders): where the file would go, and that it leaves this Mac.
private struct EnvExportCloudWarningView: View {
    let choice: EnvExportDestinationChoiceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumPlus) {
            EnvExportPath(label: String(localized: "envExport.saveTo", defaultValue: "Save to"), url: choice.fileURL)
            DialogNoteBox {
                DialogNote(
                    systemImage: "icloud",
                    text: choice.destination.cloudSyncStatus == .iCloudDesktopAndDocuments
                        ? String(
                            localized: "envExport.cloud.desktopAndDocuments.note",
                            defaultValue: "This folder syncs to iCloud (Desktop & Documents), so the file leaves this Mac and Spotlight indexes it."
                        )
                        : String(
                            localized: "envExport.cloud.drive.note",
                            defaultValue: "This folder syncs to iCloud Drive, so the file leaves this Mac and Spotlight indexes it."
                        )
                )
            }
        }
    }
}

/// Step 4: written; git checks and the `.gitignore` offer beside its note.
private struct EnvExportDoneView: View {
    let viewModel: EnvExportViewModel
    let outcome: EnvExportOutcomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumPlus) {
            EnvExportPath(label: String(localized: "envExport.savedTo", defaultValue: "Saved to"), url: outcome.result.fileURL) {
                Button(String(localized: "envExport.done.reveal", defaultValue: "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([outcome.result.fileURL])
                }
                .fxButtonStyle(.outline, size: .compact)
            }
            DialogNoteBox {
                DialogNote(
                    systemImage: "checkmark.circle",
                    text: String(
                        localized: "envExport.done.written",
                        defaultValue: "Wrote \(outcome.result.preview.exportedNames.count) values to \(outcome.result.fileURL.lastPathComponent). Only your user account can read it."
                    )
                )
                gitStatus
            }
        }
    }

    @ViewBuilder
    private var gitStatus: some View {
        switch outcome.destination.gitExposure {
        case .tracked(_, let relativePath):
            DialogNote(
                systemImage: "exclamationmark.octagon",
                text: String(
                    localized: "envExport.git.tracked",
                    defaultValue: "\(relativePath) is already committed to git. Removing it from the next commit does not remove it from history: remove it from the repository's history and rotate these values."
                ),
                tint: Theme.Colors.danger
            )
        case .notIgnored(_, let relativePath, _):
            gitignoreOffer(relativePath: relativePath)
        case .ignored:
            DialogNote(systemImage: "checkmark.shield", text: String(localized: "envExport.git.ignored", defaultValue: "git ignores this file."))
        case .outsideRepository:
            EmptyView()
        case nil:
            DialogNote(
                systemImage: "questionmark.circle",
                text: String(
                    localized: "envExport.git.failed",
                    defaultValue: "FX Vault could not check whether git ignores this file. Check it before your next commit."
                )
            )
        }
    }

    @ViewBuilder
    private func gitignoreOffer(relativePath: String) -> some View {
        switch viewModel.gitignoreState {
        case .offered:
            DialogNote(
                systemImage: "exclamationmark.triangle",
                text: String(
                    localized: "envExport.git.notIgnored.note",
                    defaultValue: "This folder is a git working tree and \(relativePath) isn’t ignored."
                )
            ) {
                Button(String(localized: "envExport.gitignore.add", defaultValue: "Add to .gitignore")) {
                    viewModel.addGitignoreEntry()
                }
                .fxButtonStyle(.outline, size: .compact)
                .keyboardShortcut(.defaultAction)
            }
        case .added(let line):
            DialogNote(systemImage: "checkmark.shield", text: String(localized: "envExport.git.added", defaultValue: "Added \(line) to .gitignore."))
        case .alreadyPresent:
            DialogNote(
                systemImage: "checkmark.shield",
                text: String(localized: "envExport.git.alreadyPresent", defaultValue: ".gitignore already lists this file.")
            )
        case .manual:
            DialogNote(
                systemImage: "exclamationmark.triangle",
                text: String(
                    localized: "envExport.git.manual",
                    defaultValue: "git does not ignore this file, and its name cannot be added automatically. Add it to .gitignore yourself."
                )
            )
        case .notApplicable:
            EmptyView()
        }
    }
}

/// A body sentence of the dialog: 13 pt, muted, wrapped.
private struct EnvExportSentence: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .fxTextStyle(.callout)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Save to" over the file's path in a field-like box (mono, middle-truncated), with an
/// optional action beside it.
private struct EnvExportPath<Accessory: View>: View {
    let label: String
    let url: URL
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        DialogStackedField(label) {
            HStack(spacing: Theme.Spacing.smallMinus) {
                Text(verbatim: url.path(percentEncoded: false))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .dialogFieldChrome()
                    .accessibilityLabel(Text(verbatim: "\(label) \(url.path(percentEncoded: false))"))
                accessory()
            }
        }
    }
}

extension EnvExportPath where Accessory == EmptyView {
    init(label: String, url: URL) {
        self.init(label: label, url: url) { EmptyView() }
    }
}

/// A skipped or unverified group: its note, then the names (never values), scrollable.
private struct EnvExportNameList: View {
    let title: String
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            DialogNote(systemImage: "exclamationmark.circle", text: title)
            ScrollView {
                Text(verbatim: names.joined(separator: ", "))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: Theme.Layout.envNameListMaxHeight)
            .padding(.leading, Theme.Layout.dialogNoteIndent)
        }
    }
}
