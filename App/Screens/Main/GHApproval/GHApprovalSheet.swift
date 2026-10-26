import GitHubKit
import SwiftUI

/// Approve on GitHub (1.0 B4b, board ConnectGitHub): gh's one-time code with Copy and Open
/// github.com/login/device, "Waiting for approval…", Check Again and Cancel. A sheet, not a
/// popover: it must stay while the user is in the browser.
struct GHApprovalSheet: View {
    @State private var viewModel: GHApprovalViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(context: GHApprovalContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: GHApprovalViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionLabel(viewModel.context.ownerLogin)
                Text(GHApprovalCopy.title(scopes: viewModel.context.scopes))
                    .fxTextStyle(.title)
                    .foregroundStyle(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(GHApprovalCopy.subtitle(login: viewModel.context.login))
                    .fxTextStyle(.body)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            buttons
        }
        .padding(Theme.Spacing.xxLarge)
        .frame(width: Theme.Layout.sheetWidth)
        .fxSheetBackground()
        .accessibilityIdentifier(AccessibilityID.GHApproval.sheet)
        .task { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .starting:
            status(GHApprovalCopy.starting, isWorking: true)
        case .waiting(let code):
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Text(GHApprovalCopy.enterCode)
                    .fxTextStyle(.formLabel)
                    .foregroundStyle(Theme.Colors.mutedText)
                HStack(spacing: Theme.Spacing.medium) {
                    Text(verbatim: code.code)
                        .fxTextStyle(.passphraseWord)
                        .foregroundStyle(Theme.Colors.ink)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(AccessibilityID.GHApproval.code)
                    Spacer(minLength: Theme.Spacing.small)
                    Button(viewModel.isCodeCopied ? GHApprovalCopy.copied : GHApprovalCopy.copy, action: viewModel.copyCode)
                        .fxButtonStyle(.outline)
                        .accessibilityIdentifier(AccessibilityID.GHApproval.copyCode)
                }
                if let url = GHDeviceCodeModel.verificationURL {
                    Button(GHApprovalCopy.openDevicePage) { openURL(url) }
                        .fxButtonStyle(.outline)
                        .accessibilityIdentifier(AccessibilityID.GHApproval.openDevicePage)
                }
                status(GHApprovalCopy.waiting, isWorking: true)
            }
        case .approved:
            status(GHApprovalCopy.approved, isWorking: false)
        case .failed(let error):
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                InlineErrorView(error: error.presentation)
                CommandRow(command: viewModel.commandText, isCopied: viewModel.isCommandCopied) { _ in
                    viewModel.copyCommand()
                }
            }
        }
    }

    private func status(_ text: String, isWorking: Bool) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Text(text)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.GHApproval.status)
    }

    private var buttons: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            if viewModel.isChecking {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            if viewModel.phase == .approved {
                Button(GHApprovalCopy.done) { dismiss() }
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(GHApprovalCopy.cancel) {
                    viewModel.cancel()
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AccessibilityID.GHApproval.cancel)
                if case .failed = viewModel.phase {
                    Button(GHApprovalCopy.tryAgain, action: viewModel.start)
                        .fxButtonStyle(.secondary, size: .large)
                        .accessibilityIdentifier(AccessibilityID.GHApproval.tryAgain)
                }
                Button(GHApprovalCopy.checkAgain) {
                    Task { await viewModel.checkAgain() }
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isChecking)
                .accessibilityIdentifier(AccessibilityID.GHApproval.checkAgain)
            }
        }
    }
}

/// The sheet's texts.
enum GHApprovalCopy {
    static func title(scopes: [GHApprovalScope]) -> String {
        let list = scopes.map(\.rawValue).joined(separator: ", ")
        return String(localized: "ghApproval.title", defaultValue: "Approve \(list) on GitHub")
    }

    static func subtitle(login: String) -> String {
        String(
            localized: "ghApproval.subtitle",
            defaultValue: "GitHub CLI asks GitHub for it on \(login). Enter the code on GitHub and approve; FX Vault never sees your token."
        )
    }

    static let starting = String(localized: "ghApproval.starting", defaultValue: "Asking GitHub CLI for a code…")
    static let enterCode = String(localized: "ghApproval.enterCode", defaultValue: "Enter this code on GitHub")
    static let waiting = String(localized: "ghApproval.waiting", defaultValue: "Waiting for approval…")
    static let approved = String(localized: "ghApproval.approved", defaultValue: "Approved · checked again")
    static let openDevicePage = String(
        localized: "ghApproval.openDevicePage",
        defaultValue: "Open \(GHDeviceCodeModel.verificationHost)"
    )
    static let copy = String(localized: "command.copy", defaultValue: "Copy")
    static let copied = String(localized: "command.copied", defaultValue: "Copied")
    static let checkAgain = String(localized: "ghApproval.checkAgain", defaultValue: "Check Again")
    static let tryAgain = String(localized: "ghApproval.tryAgain", defaultValue: "Try Again")
    static let cancel = String(localized: "common.cancel", defaultValue: "Cancel")
    static let done = String(localized: "common.done", defaultValue: "Done")
}
