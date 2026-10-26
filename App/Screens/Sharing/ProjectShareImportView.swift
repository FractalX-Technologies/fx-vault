import SharingKit
import SwiftUI
import VaultCore
import VaultData

/// A project share's preview (v0.9.0, P7; board Share-OpenPreview): the sender (unverified), the
/// replay warning, what the file adds per repository and, for the selected repository, today's
/// preview of its GitHub scopes plus its destinations; then the folders.
struct ProjectShareImportView: View {
    let editor: ProjectShareImportEditor
    let isOnline: Bool

    var body: some View {
        ProjectShareSenderView(sender: editor.sender)
        if editor.plan.requiresReplayConfirmation {
            replayWarning
        }
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            Text(ProjectShareCopy.whatItAdds)
                .fxTextStyle(.formLabel)
                .foregroundStyle(Theme.Colors.mutedText)
            repositoryList
        }
        if let repository = editor.selectedRepository {
            ProjectShareRepositoryPreview(editor: editor, repository: repository)
        }
        if !editor.plan.folders.isEmpty {
            folders
        }
        if editor.needsRepositoryImport, !isOnline {
            ShareNoteView(systemImage: "wifi.slash", text: ConnectivityCopy.offlineHelp, tint: Theme.Colors.warning)
        }
    }

    private var replayWarning: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ForEach(Array(editor.plan.replayWarnings).sorted { $0.rawValue < $1.rawValue }, id: \.self) { warning in
                ShareNoteView(
                    systemImage: "clock.badge.exclamationmark",
                    text: warning.localizedMessage,
                    tint: Theme.Colors.warning
                )
            }
            Toggle(
                String(localized: "share.preview.replay.confirm", defaultValue: "Import anyway"),
                isOn: Binding(
                    get: { editor.confirmsReplay },
                    set: { editor.confirmsReplay = $0 }
                )
            )
            .toggleStyle(.checkbox)
            .fxTextStyle(.callout)
            .foregroundStyle(Theme.Colors.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fxCalloutBackground()
    }

    private var repositoryList: some View {
        VStack(spacing: 0) {
            ForEach(Array(editor.repositoryRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    HairlineDivider()
                }
                ProjectShareRepositoryRow(row: row, isSelected: row.id == editor.selectedRepositoryID) {
                    editor.selectedRepositoryID = row.id
                }
            }
        }
        .clipShape(.rect(cornerRadius: CardStyle.dialog.radius))
        .fxCardBackground(.dialog)
    }

    /// The folders in the file, each with what happens to it.
    private var folders: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            Text(ProjectShareCopy.folders)
                .fxTextStyle(.formLabel)
                .foregroundStyle(Theme.Colors.mutedText)
            VStack(spacing: 0) {
                ForEach(Array(editor.plan.folders.enumerated()), id: \.element.id) { index, folder in
                    if index > 0 {
                        HairlineDivider()
                    }
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "folder")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .accessibilityHidden(true)
                        Text(verbatim: folder.name)
                            .fxTextStyle(.caption)
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(1)
                        Text(verbatim: ProjectShareCopy.counts(folder.counts))
                            .font(Theme.Typography.monoLabel)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Spacing.small)
                        DialogPopUp(
                            title: ProjectShareCopy.folders,
                            selection: Binding(
                                get: { folder.action },
                                set: { editor.setFolderAction($0, for: folder) }
                            ),
                            options: editor.folderActions(for: folder).map {
                                .init(value: $0, title: ProjectShareImportEditor.title(of: $0))
                            }
                        )
                        .frame(width: Theme.Layout.shareActionPickerWidth)
                    }
                    .padding(.horizontal, Theme.Spacing.medium)
                    .frame(minHeight: Theme.Layout.shareOpenRowHeight)
                    .padding(.vertical, Theme.Spacing.xSmall)
                }
            }
            .fxCardBackground(.dialog)
        }
    }
}

/// Who the file says sent it, marked not verified.
private struct ProjectShareSenderView: View {
    let sender: ShareFileSenderModel

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityHidden(true)
            Text(ProjectShareCopy.from(sender.displayName))
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.ink)
            DialogTag(title: ProjectShareCopy.unverified)
                .help(ProjectShareCopy.unverifiedHelp)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One repository the file adds to (board Share-OpenPreview): the symbol, the mono name and its
/// owner, then a dot and what happens (✓ in the vault with the counts, ⇣ imported from GitHub
/// first, ✕ skipped). Selecting it shows its preview below.
private struct ProjectShareRepositoryRow: View {
    let row: ProjectShareImportEditor.RepositoryRowModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: Theme.Symbols.repository)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .accessibilityHidden(true)
                Text(verbatim: nameParts.name)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(row.mark == .skipped ? Theme.Colors.mutedText : Theme.Colors.ink)
                    .lineLimit(1)
                if let owner = nameParts.owner {
                    Text(verbatim: owner)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.small)
                HStack(spacing: Theme.Spacing.smallMinus) {
                    mark
                    Text(verbatim: status)
                        .fxTextStyle(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(height: Theme.Layout.shareOpenRowHeight)
            .background(isSelected ? Theme.Colors.surface : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    /// `owner/name` read as the name, then its owner.
    private var nameParts: (owner: String?, name: String) {
        let parts = row.fullName.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : (nil, row.fullName)
    }

    /// "Already in your vault · 3 secrets · 1 variable"; a skipped repository says why only.
    private var status: String {
        let counts = row.mark == .skipped ? "" : ProjectShareCopy.counts(row.counts)
        return [row.detail, counts].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var mark: some View {
        switch row.mark {
        case .inVault:
            Circle()
                .fill(Theme.Colors.success)
                .frame(width: Theme.Layout.statusDotSize, height: Theme.Layout.statusDotSize)
                .accessibilityHidden(true)
        case .willImport:
            RingDot()
        case .skipped:
            Circle()
                .fill(Theme.Colors.hairlineStrong)
                .frame(width: Theme.Layout.statusDotSize, height: Theme.Layout.statusDotSize)
                .accessibilityHidden(true)
        }
    }

    private var statusColor: Color {
        switch row.mark {
        case .inVault, .skipped: Theme.Colors.mutedText
        case .willImport: Theme.Colors.ink
        }
    }
}

/// The selected repository: its GitHub scopes (today's preview) and its destinations.
private struct ProjectShareRepositoryPreview: View {
    let editor: ProjectShareImportEditor
    let repository: ShareBundleRepositoryPlanModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let github = editor.githubEditor(for: repository) {
                ShareImportPreviewView(editor: github, isStandalone: false)
            } else if case .noAccess = repository.status {
                ShareNoteView(systemImage: "arrow.clockwise", text: ProjectShareCopy.skippedLater, tint: Theme.Colors.subtleText)
            }
            if !repository.summary.retiredDestinations.isEmpty {
                ShareNoteView(
                    systemImage: "minus.circle",
                    text: ProjectShareCopy.retiredDestinations(repository.summary.retiredDestinations),
                    tint: Theme.Colors.subtleText
                )
            }
            if !repository.destinations.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    SectionLabel(ProjectShareCopy.destinations)
                    ForEach(repository.destinations) { destination in
                        ProjectShareDestinationPreview(editor: editor, destination: destination, isImportedNow: repository.status.isImportedNow)
                    }
                }
            }
        }
    }
}

/// One incoming destination and its items.
private struct ProjectShareDestinationPreview: View {
    let editor: ProjectShareImportEditor
    let destination: ShareDestinationPlanModel
    let isImportedNow: Bool

    var body: some View {
        Card(.container, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: destination.target.provider.symbolName)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .accessibilityHidden(true)
                    Text(verbatim: title)
                        .fxTextStyle(.calloutEmphasized)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let stage = destination.stage {
                        StatusChip(title: stage, tone: StageRisk.isProduction(stage) ? .warning : .neutral)
                    }
                    Spacer(minLength: 0)
                }
                Text(destination.localDestinationID == nil ? ProjectShareCopy.newDestination : ProjectShareCopy.mergedDestination)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.Spacing.small)
            .padding(.horizontal, Theme.Spacing.large)
            ForEach(destination.items) { item in
                HairlineDivider()
                ShareImportActionRow(
                    kind: item.kind,
                    name: item.name,
                    warnings: item.warnings,
                    chip: item.chip,
                    allowedActions: isImportedNow ? item.allowedActions : [item.action],
                    action: item.action
                ) { action in
                    editor.select(action, forDestinationItem: item.id)
                }
                .padding(.horizontal, Theme.Spacing.large)
            }
        }
    }

    private var title: String {
        "\(destination.target.provider.title) · \(destination.target.displayName)"
    }
}

/// What a project share import changed (names and counts only).
struct ProjectShareImportResultView: View {
    let result: ShareBundleImportResultModel
    let failedRepositories: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ShareNoteView(
                systemImage: "checkmark.circle",
                text: String(localized: "shareImport.done.title", defaultValue: "Imported into your vault"),
                tint: Theme.Colors.success
            )
            Card(.container, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    if index > 0 {
                        HairlineDivider()
                    }
                    Text(line)
                        .fxTextStyle(.callout)
                        .foregroundStyle(Theme.Colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Spacing.medium)
                        .padding(.horizontal, Theme.Spacing.large)
                }
            }
            if !failedRepositories.isEmpty {
                ShareNoteView(
                    systemImage: "exclamationmark.triangle",
                    text: ProjectShareCopy.importFailed(failedRepositories),
                    tint: Theme.Colors.warning
                )
            }
            if result.heldCount > 0 {
                SheetCallout(systemImage: "tray.and.arrow.down", tint: Theme.Colors.brand, text: ProjectShareCopy.doneHeld(result.heldCount))
            }
        }
    }

    var lines: [String] {
        var lines: [String] = []
        if !result.repositories.isEmpty {
            lines.append(ProjectShareCopy.doneRepositories(result.repositories.count))
        }
        if !result.destinationsCreated.isEmpty {
            lines.append(ProjectShareCopy.doneDestinations(result.destinationsCreated.count))
        }
        if result.destinationItemsWritten > 0 {
            lines.append(ProjectShareCopy.doneDestinationItems(result.destinationItemsWritten))
        }
        if !result.folders.isEmpty {
            lines.append(ProjectShareCopy.doneFolders(result.folders.count))
        }
        if result.linkGroupCount > 0 {
            lines.append(ProjectShareCopy.doneLinks(result.linkGroupCount))
        }
        if lines.isEmpty {
            lines.append(ProjectShareCopy.doneNothing)
        }
        return lines
    }
}
