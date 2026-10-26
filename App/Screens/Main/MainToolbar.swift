import SwiftUI

/// Installs the toolbar. The window title is drawn by ``MainToolbarTitle`` (the selected place's
/// path), so the system title is removed.
struct MainToolbarModifier: ViewModifier {
    let viewModel: MainViewModel

    func body(content: Content) -> some View {
        content
            .toolbar { MainToolbar(viewModel: viewModel) }
            .toolbar(removing: .title)
    }
}

/// The toolbar (§10 Toolbar; boards Main2-Home, Main2-Repository, Main2-Search), on the system's
/// glass toolbar: the selected place's path as the title, the ⌘K search button on its own glass,
/// then the ink Sync pill. New Repository, Import .env and Share left it in 1.0 (D6c2): they stay
/// as ⌘N (and an owner's menu), ⇧⌘I and ⌥⌘S.
private struct MainToolbar: ToolbarContent {
    let viewModel: MainViewModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            MainToolbarTitle(viewModel: viewModel)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            JumpToolbarButton(viewModel: viewModel)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        // The pill has its own ink fill; the shared glass would wrap it in a second capsule.
        ToolbarItem(placement: .primaryAction) {
            MainSyncButton(viewModel: viewModel)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// The selected place as a sans path (``MainViewModel/breadcrumb``): the steps muted, the last
/// one semibold in ink; "FX Vault" with nothing selected; the DEV chip in Debug builds. It is
/// `toolbarTitleWidth` wide: a long path drops its first steps down to the last one, then shows
/// the app name, rather than pushing the buttons.
struct MainToolbarTitle: View {
    let viewModel: MainViewModel

    var body: some View {
        let path = viewModel.breadcrumb
        HStack(spacing: Theme.Spacing.small) {
            ViewThatFits(in: .horizontal) {
                ForEach(Self.fallbacks(path), id: \.self) { steps in
                    row(steps)
                }
            }
            if AppIdentity.isDevelopmentBuild {
                DevBuildBadge()
            }
        }
        .frame(width: Theme.Layout.toolbarTitleWidth, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.small)
        .help(path.joined(separator: Self.separator))
    }

    private static let separator = " › "

    /// The rows to try, widest first: the path, its tails down to the last step, then the app name.
    static func fallbacks(_ path: [String]) -> [[String]] {
        path.indices.map { Array(path.dropFirst($0)) } + [[]]
    }

    /// The steps as one text, so VoiceOver and the UI tests read the whole path.
    static func pathText(_ steps: [String]) -> AttributedString {
        var text = AttributedString()
        for (index, step) in steps.enumerated() {
            if index > 0 {
                var separator = AttributedString(Self.separator)
                separator.foregroundColor = Theme.Colors.faintText
                text += separator
            }
            let isLast = index == steps.count - 1
            var name = AttributedString(step)
            name.font = isLast ? Theme.Typography.calloutEmphasized : Theme.Typography.callout
            name.foregroundColor = isLast ? Theme.Colors.ink : Theme.Colors.mutedText
            text += name
        }
        return text
    }

    @ViewBuilder
    private func row(_ steps: [String]) -> some View {
        if steps.isEmpty {
            Text(AppIdentity.windowTitle)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .lineLimit(1)
                .fixedSize()
        } else {
            Text(Self.pathText(steps))
                .font(Theme.Typography.callout)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier(AccessibilityID.Main.breadcrumb)
        }
    }
}

/// The search button with its ⌘K key (boards Main2-Home, Main2-Search): opens the jump palette.
private struct JumpToolbarButton: View {
    let viewModel: MainViewModel

    var body: some View {
        Button {
            viewModel.showJumpPalette()
        } label: {
            HStack(spacing: Theme.Spacing.smallMinus) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.Typography.caption)
                KeyHint("⌘K")
            }
            .foregroundStyle(Theme.Colors.mutedText)
            .padding(.horizontal, Theme.Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canJump)
        .help(JumpPaletteCopy.jumpAnywhereHelp)
        .accessibilityLabel(JumpPaletteCopy.jumpAnywhere)
        .accessibilityIdentifier(AccessibilityID.Main.jumpAnywhere)
    }
}

/// The ink Sync pill with the mono pending count; 40% while it cannot run (offline included).
private struct MainSyncButton: View {
    let viewModel: MainViewModel

    var body: some View {
        SyncToolbarButton(
            count: viewModel.pendingChangeCount,
            isSyncing: viewModel.isSyncing,
            isEnabled: viewModel.canSync,
            unavailableReason: viewModel.isOnline ? nil : ConnectivityCopy.offlineHelp
        ) {
            viewModel.sync()
        }
    }
}

/// "DEV" in the toolbar of Debug builds (FX Vault Dev), which use their own vault folder.
private struct DevBuildBadge: View {
    var body: some View {
        StatusChip(
            title: String(localized: "toolbar.devBuild", defaultValue: "DEV"),
            tone: .warning
        )
        .help(String(
            localized: "toolbar.devBuild.help",
            defaultValue: "Development build (FX Vault Dev). It uses the FX Vault Dev vault, not the vault of the installed FX Vault."
        ))
        .accessibilityLabel(String(localized: "toolbar.devBuild.accessibility", defaultValue: "Development build"))
    }
}
