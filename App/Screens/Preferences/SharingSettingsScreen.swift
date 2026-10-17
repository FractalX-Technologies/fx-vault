import SwiftUI
import VaultCore

/// Preferences › Sharing (v0.9.0): the share files this Mac sent, with the names to rotate if one
/// leaks. See ``SharingSettingsViewModel``.
struct SharingSettingsScreen: View {
    let viewModel: SharingSettingsViewModel

    var body: some View {
        if viewModel.isUnlocked {
            SharingSettingsContent(viewModel: viewModel)
        } else {
            VaultSettingsLockedView()
        }
    }
}

private struct SharingSettingsContent: View {
    @Bindable var viewModel: SharingSettingsViewModel

    var body: some View {
        PreferencesPage {
            PreferencesSection(ProjectShareCopy.settingsTitle, footnote: ProjectShareCopy.settingsHelp) {
                if viewModel.entries.isEmpty {
                    PreferencesBlock {
                        Text(ProjectShareCopy.settingsEmpty)
                            .fxTextStyle(.body)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(viewModel.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        HairlineDivider()
                    }
                    SentShareRow(entry: entry) {
                        viewModel.requestRemoval(entry)
                    }
                }
            }
        }
        .confirmationDialog(
            ProjectShareCopy.removeEntry,
            isPresented: Binding(
                get: { viewModel.pendingRemoval != nil },
                set: { if !$0 { viewModel.pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(ProjectShareCopy.removeEntry, role: .destructive) {
                Task { await viewModel.confirmRemoval() }
            }
        } message: {
            Text(ProjectShareCopy.removeEntryHelp)
        }
        .errorAlert($viewModel.alert)
    }
}

/// One sent file: date, expiry, recipients, repositories and stages, and the names inside.
private struct SentShareRow: View {
    let entry: SharingSettingsViewModel.EntryModel
    let onRemove: () -> Void
    @State private var showsNames = false

    var body: some View {
        PreferencesBlock(spacing: Theme.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .fxTextStyle(.bodyEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                if entry.isExpired {
                    StatusChip(title: ProjectShareCopy.expired, tone: .neutral)
                } else {
                    Text(ProjectShareCopy.expires(entry.expiresAt))
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.subtleText)
                }
                Spacer(minLength: Theme.Spacing.small)
                Menu {
                    Button(ProjectShareCopy.removeEntry, role: .destructive, action: onRemove)
                } label: {
                    Label(String(localized: "main.detail.actions", defaultValue: "Actions"), systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fxIconButtonStyle()
            }
            Text(entry.recipients)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.ink)
            if !entry.repositories.isEmpty || !entry.stages.isEmpty {
                Text(verbatim: (entry.repositories + entry.stages).joined(separator: " · "))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            DisclosureGroup(isExpanded: $showsNames) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    ShareNoteView(systemImage: "arrow.triangle.2.circlepath", text: ProjectShareCopy.rotateHint, tint: Theme.Colors.warning)
                    ForEach(entry.places) { place in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                            Text(verbatim: place.title)
                                .fxTextStyle(.calloutEmphasized)
                                .foregroundStyle(Theme.Colors.ink)
                            if !place.secretNames.isEmpty {
                                Text(verbatim: place.secretNames.joined(separator: ", "))
                                    .fxTextStyle(.monoMeta)
                                    .foregroundStyle(Theme.Colors.ink)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !place.variableNames.isEmpty {
                                Text(verbatim: place.variableNames.joined(separator: ", "))
                                    .fxTextStyle(.monoMeta)
                                    .foregroundStyle(Theme.Colors.subtleText)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.top, Theme.Spacing.xSmall)
            } label: {
                Text(verbatim: "\(ProjectShareCopy.namesInFile) · \(ProjectShareCopy.secretNames(entry.secretCount))")
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
    }
}
