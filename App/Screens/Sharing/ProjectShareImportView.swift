import SharingKit
import SwiftUI
import VaultCore
import VaultData

/// A project share's preview in Import Share (v0.9.0, P7): the sender (unverified), the dates, the replay warning, the repository list (✓ ⇣ ✕) and, for the selected
/// repository, today's preview of its GitHub scopes plus its destinations; then the folders.
struct ProjectShareImportView: View {
    let editor: ProjectShareImportEditor
    let isOnline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ProjectShareSenderView(sender: editor.sender, createdAt: editor.createdAt, expiresAt: editor.expiresAt)
            if editor.plan.requiresReplayConfirmation {
                replayWarning
            }
            repositoryList
            if let repository = editor.selectedRepository {
                ProjectShareRepositoryPreview(editor: editor, repository: repository)
            }
            if !editor.plan.folders.isEmpty {
                folders
            }
            ShareNoteView(systemImage: "tray.and.arrow.down", text: ProjectShareCopy.nothingSyncs)
            if editor.needsRepositoryImport, !isOnline {
                ShareNoteView(systemImage: "wifi.slash", text: ConnectivityCopy.offlineHelp, tint: Theme.Colors.warning)
            }
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
        Card(.container, spacing: 0) {
            ForEach(Array(editor.repositoryRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    HairlineDivider()
                }
                ProjectShareRepositoryRow(row: row, isSelected: row.id == editor.selectedRepositoryID) {
                    editor.selectedRepositoryID = row.id
                }
            }
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(ProjectShareCopy.folders)
            Card(.container, spacing: 0) {
                ForEach(Array(editor.plan.folders.enumerated()), id: \.element.id) { index, folder in
                    if index > 0 {
                        HairlineDivider()
                    }
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Theme.Colors.subtleText)
                            .accessibilityHidden(true)
                        Text(verbatim: folder.name)
                            .fxTextStyle(.calloutEmphasized)
                            .foregroundStyle(Theme.Colors.ink)
                        Text(ShareSummaryLineModel.counts(folder.counts))
                            .fxTextStyle(.monoMeta)
                            .foregroundStyle(Theme.Colors.subtleText)
                        Spacer(minLength: Theme.Spacing.small)
                        Picker(
                            ProjectShareCopy.folders,
                            selection: Binding(
                                get: { folder.action },
                                set: { editor.setFolderAction($0, for: folder) }
                            )
                        ) {
                            ForEach(editor.folderActions(for: folder), id: \.self) { action in
                                Text(ProjectShareImportEditor.title(of: action)).tag(action)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(.vertical, Theme.Spacing.small)
                    .padding(.horizontal, Theme.Spacing.large)
                }
            }
        }
    }
}

/// Who sent the file and when it expires.
struct ProjectShareSenderView: View {
    let sender: ShareFileSenderModel
    let createdAt: Date
    let expiresAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Theme.Colors.subtleText)
                    .accessibilityHidden(true)
                Text(ProjectShareCopy.from(sender.displayName))
                    .fxTextStyle(.bodyEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                StatusChip(title: ProjectShareCopy.unverified, tone: .warning)
                    .help(ProjectShareCopy.unverifiedHelp)
            }
            Text(ProjectShareCopy.dates(created: createdAt, expires: expiresAt))
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.subtleText)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One repository line: ✓ ⇣ ✕, the name, the counts and what happens to it.
private struct ProjectShareRepositoryRow: View {
    let row: ProjectShareImportEditor.RepositoryRowModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: row.fullName)
                        .fxTextStyle(.monoName)
                        .foregroundStyle(row.mark == .skipped ? Theme.Colors.mutedText : Theme.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.detail)
                        .fxTextStyle(.caption)
                        .foregroundStyle(row.mark == .skipped ? Theme.Colors.warning : Theme.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.small)
                Text(ShareSummaryLineModel.counts(row.counts))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.subtleText)
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(isSelected ? Theme.Colors.brand : Theme.Colors.subtleText)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Theme.Spacing.small)
            .padding(.horizontal, Theme.Spacing.large)
            .background(isSelected ? Theme.Colors.surface2 : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    private var symbol: String {
        switch row.mark {
        case .inVault: "checkmark.circle.fill"
        case .willImport: "arrow.down.circle"
        case .skipped: "xmark.circle"
        }
    }

    private var tint: Color {
        switch row.mark {
        case .inVault: Theme.Colors.success
        case .willImport: Theme.Colors.brand
        case .skipped: Theme.Colors.warning
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
        switch destination.target {
        case .vercel(_, let projectName, _, let environment): "\(destination.target.provider.title) · \(projectName) · \(environment.title)"
        default: "\(destination.target.provider.title) · \(destination.target.displayName)"
        }
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
