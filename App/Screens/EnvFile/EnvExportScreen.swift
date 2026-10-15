import AppKit
import EnvTools
import SwiftUI
import VaultData

/// EnvExportScreen: ReauthGate → warnings (plaintext, iCloud, tracked file) → save panel → gitignore offer.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet`. The init signature is fixed; the feature owns everything else in this folder.
/// Dismiss with `@Environment(\.dismiss)`.
struct EnvExportScreen: View {
    @State private var viewModel: EnvExportViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: EnvExportContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: EnvExportViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: ShareSheetLabel.environmentFile,
                title: String(localized: "envExport.title", defaultValue: "Export .env"),
                subtitle: subtitle
            )
            content
            footer
        }
        .fxSheetContent()
        .frame(width: Theme.Layout.envExportSheetWidth)
        .errorAlert($viewModel.alert)
        .onDisappear { viewModel.discard() }
    }

    private var subtitle: String {
        if viewModel.scopeTitle.isEmpty {
            return String(localized: "envExport.subtitle.unknown", defaultValue: "Write this scope's values to a .env file.")
        }
        return String(
            localized: "envExport.subtitle",
            defaultValue: "\(viewModel.repositoryName) · \(viewModel.scopeTitle)"
        )
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

    private var footer: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            switch viewModel.step {
            case .authenticate:
                cancelButton
                Spacer()
                progress
                if viewModel.showsTouchIDButton {
                    Button {
                        Task { await viewModel.authenticateWithTouchID() }
                    } label: {
                        Label(String(localized: "envExport.auth.touchID", defaultValue: "Use Touch ID"), systemImage: "touchid")
                    }
                    .disabled(!viewModel.canAuthenticateWithTouchID)
                    .modifier(DefaultActionModifier(isDefault: viewModel.defaultAction == .touchID))
                }
                Button(String(localized: "envExport.auth.continue", defaultValue: "Continue")) {
                    Task { await viewModel.authenticateWithPassword() }
                }
                .disabled(!viewModel.canAuthenticateWithPassword)
                .modifier(DefaultActionModifier(isDefault: viewModel.defaultAction == .password))
            case .review:
                cancelButton
                Spacer()
                progress
                Button(String(localized: "envExport.chooseLocation", defaultValue: "Choose Location…"), action: chooseLocation)
                    .disabled(viewModel.isWorking)
                    .modifier(DefaultActionModifier(isDefault: true))
            case .confirmCloudSync:
                cancelButton
                Spacer()
                progress
                Button(String(localized: "envExport.cloud.exportAnyway", defaultValue: "Export Anyway")) {
                    Task { await viewModel.confirmCloudSyncExport() }
                }
                .disabled(viewModel.isWorking)
                Button(String(localized: "envExport.cloud.chooseAnother", defaultValue: "Choose Another Location")) {
                    viewModel.chooseAnotherLocation()
                    chooseLocation()
                }
                .disabled(viewModel.isWorking)
                .modifier(DefaultActionModifier(isDefault: true))
            case .done:
                Spacer()
                if viewModel.defaultAction == .addToGitignore {
                    Button(String(localized: "envExport.gitignore.notNow", defaultValue: "Not Now")) { dismiss() }
                        .fxButtonStyle(.secondary, size: .large)
                        .keyboardShortcut(.cancelAction)
                    Button(String(localized: "envExport.gitignore.add", defaultValue: "Add to .gitignore")) {
                        viewModel.addGitignoreEntry()
                    }
                    .modifier(DefaultActionModifier(isDefault: true))
                } else {
                    Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                        .modifier(DefaultActionModifier(isDefault: true))
                }
            }
        }
    }

    private var cancelButton: some View {
        Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
            .fxButtonStyle(.secondary, size: .large)
            .keyboardShortcut(.cancelAction)
    }

    @ViewBuilder
    private var progress: some View {
        if viewModel.isWorking {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func chooseLocation() {
        guard let url = EnvFilePanels.chooseExportDestination(
            fileName: viewModel.suggestedFileName,
            directory: viewModel.suggestedDirectory
        ) else { return }
        Task { await viewModel.chooseDestination(url) }
    }
}

/// Makes a button the primary Return pill when `isDefault`; otherwise a secondary pill.
private struct DefaultActionModifier: ViewModifier {
    let isDefault: Bool

    func body(content: Content) -> some View {
        if isDefault {
            content
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
        } else {
            content
                .fxButtonStyle(.secondary, size: .large)
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
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            if viewModel.preview == nil {
                ProgressView()
                    .controlSize(.small)
            } else if !viewModel.hasSomethingToExport {
                SheetCallout(
                    systemImage: "tray",
                    tint: Theme.Colors.subtleText,
                    text: String(
                        localized: "envExport.nothing",
                        defaultValue: "This scope has no values to export. Secrets without a value in FX Vault are never exported."
                    )
                )
            } else {
                Text(String(
                    localized: "envExport.auth.message",
                    defaultValue: "Exporting writes \(viewModel.exportedCount) values to a file in plaintext. Confirm it's you with Touch ID or your master password."
                ))
                .fxTextStyle(.body)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
                    SectionLabel(passwordLabel)
                        .accessibilityHidden(true)
                    SecureField(passwordLabel, text: $viewModel.password)
                        .focused($isPasswordFocused)
                        .fxInputField(.rounded, isFocused: isPasswordFocused, isInvalid: viewModel.authError != nil)
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

/// Step 2: the plaintext warning and what is left out.
private struct EnvExportReviewView: View {
    let viewModel: EnvExportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SheetCallout(
                systemImage: "exclamationmark.triangle.fill",
                tint: Theme.Colors.danger,
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
                    names: viewModel.valueMissingNames,
                    tint: Theme.Colors.warning
                )
            }
            if !viewModel.nameCollisions.isEmpty {
                EnvExportNameList(
                    title: String(
                        localized: "envExport.skipped.collisions",
                        defaultValue: "Skipped: \(viewModel.nameCollisions.count) variables share a name with an exported secret"
                    ),
                    names: viewModel.nameCollisions,
                    tint: Theme.Colors.warning
                )
            }
            if !viewModel.unverifiedShareNames.isEmpty {
                EnvExportNameList(
                    title: String(
                        localized: "envExport.unverifiedShare",
                        defaultValue: "\(viewModel.unverifiedShareNames.count) values came from a share and are not verified on GitHub yet"
                    ),
                    names: viewModel.unverifiedShareNames,
                    tint: Theme.Colors.warning
                )
            }
        }
    }
}

/// Step 3 (only for synced folders): the iCloud and Spotlight warning.
private struct EnvExportCloudWarningView: View {
    let choice: EnvExportDestinationChoiceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SheetCallout(
                systemImage: "icloud.fill",
                tint: Theme.Colors.danger,
                text: choice.destination.cloudSyncStatus == .iCloudDesktopAndDocuments
                    ? String(
                        localized: "envExport.cloud.desktopAndDocuments",
                        defaultValue: "This folder syncs to iCloud (Desktop & Documents). The plaintext file would be uploaded to iCloud and indexed by Spotlight."
                    )
                    : String(
                        localized: "envExport.cloud.drive",
                        defaultValue: "This folder syncs to iCloud Drive. The plaintext file would be uploaded to iCloud and indexed by Spotlight."
                    )
            )
            Text(verbatim: choice.fileURL.path(percentEncoded: false))
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.subtleText)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

/// Step 4: written; git checks and the `.gitignore` offer.
private struct EnvExportDoneView: View {
    let viewModel: EnvExportViewModel
    let outcome: EnvExportOutcomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SheetCallout(
                systemImage: "checkmark.circle.fill",
                tint: Theme.Colors.success,
                text: String(
                    localized: "envExport.done.written",
                    defaultValue: "Wrote \(outcome.result.preview.exportedNames.count) values to \(outcome.result.fileURL.lastPathComponent). Only your user account can read it."
                )
            )
            HStack {
                Text(verbatim: outcome.result.fileURL.path(percentEncoded: false))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(String(localized: "envExport.done.reveal", defaultValue: "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([outcome.result.fileURL])
                }
                .fxLinkButtonStyle(isEmphasized: true)
            }
            gitStatus
        }
    }

    @ViewBuilder
    private var gitStatus: some View {
        switch outcome.destination.gitExposure {
        case .tracked(_, let relativePath):
            SheetCallout(
                systemImage: "exclamationmark.octagon.fill",
                tint: Theme.Colors.danger,
                text: String(
                    localized: "envExport.git.tracked",
                    defaultValue: "\(relativePath) is already committed to git. Removing it from the next commit does not remove it from history: remove it from the repository's history and rotate these values."
                )
            )
        case .notIgnored(_, let relativePath, _):
            gitignoreOffer(relativePath: relativePath)
        case .ignored:
            SheetCallout(
                systemImage: "checkmark.shield",
                tint: Theme.Colors.success,
                text: String(localized: "envExport.git.ignored", defaultValue: "git ignores this file.")
            )
        case .outsideRepository:
            EmptyView()
        case nil:
            SheetCallout(
                systemImage: "questionmark.circle",
                tint: Theme.Colors.warning,
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
        case .offered(let line):
            SheetCallout(
                systemImage: "exclamationmark.triangle.fill",
                tint: Theme.Colors.warning,
                text: String(
                    localized: "envExport.git.notIgnored",
                    defaultValue: "git does not ignore \(relativePath). Add \(line) to the repository's .gitignore so it is never committed?"
                )
            )
        case .added(let line):
            SheetCallout(
                systemImage: "checkmark.shield",
                tint: Theme.Colors.success,
                text: String(localized: "envExport.git.added", defaultValue: "Added \(line) to .gitignore.")
            )
        case .alreadyPresent:
            SheetCallout(
                systemImage: "checkmark.shield",
                tint: Theme.Colors.success,
                text: String(localized: "envExport.git.alreadyPresent", defaultValue: ".gitignore already lists this file.")
            )
        case .manual:
            SheetCallout(
                systemImage: "exclamationmark.triangle.fill",
                tint: Theme.Colors.warning,
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

/// A titled, scrollable list of names (never values).
private struct EnvExportNameList: View {
    let title: String
    let names: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label {
                Text(verbatim: title)
                    .fxTextStyle(.calloutEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(tint)
            }
            ScrollView {
                Text(verbatim: names.joined(separator: ", "))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: Theme.Layout.envNameListMaxHeight)
        }
    }
}
