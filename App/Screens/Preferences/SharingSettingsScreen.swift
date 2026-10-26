import SwiftUI
import VaultCore

/// Preferences › Sharing (v0.9.0; board Settings-Sharing): the share files this Mac sent, with
/// the names to rotate if one leaks. See ``SharingSettingsViewModel``.
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
            PreferencesSection(ProjectShareCopy.settingsTitle, footnote: ProjectShareCopy.settingsFootnote) {
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

/// One sent file (board Settings-Sharing): when it was made and whether it still opens, what it
/// holds and until when, then its names on demand, by place.
private struct SentShareRow: View {
    let entry: SharingSettingsViewModel.EntryModel
    let onRemove: () -> Void
    @State private var showsNames = false

    var body: some View {
        PreferencesBlock(spacing: Theme.Spacing.xxSmall) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "doc")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .frame(width: Theme.Layout.settingsNamesIndent - Theme.Spacing.small)
                    .accessibilityHidden(true)
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Typography.captionEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.small)
                PreferencesStatus(
                    title: entry.isExpired ? ProjectShareCopy.expired : ProjectShareCopy.active,
                    mark: entry.isExpired ? .idle : .fine
                )
                Menu {
                    Button(ProjectShareCopy.removeEntry, role: .destructive, action: onRemove)
                } label: {
                    Label(String(localized: "main.detail.actions", defaultValue: "Actions"), systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fxIconButtonStyle(.ghost, size: .compact)
            }
            Group {
                Text(verbatim: detail)
                    .fxTextStyle(.formNote)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showsNames.toggle()
                } label: {
                    Label(
                        showsNames ? ProjectShareCopy.hideNames : ProjectShareCopy.showNames,
                        systemImage: showsNames ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill"
                    )
                    .labelStyle(SentShareDisclosureLabelStyle())
                }
                .buttonStyle(.plain)
                if showsNames {
                    names
                }
            }
            .padding(.leading, Theme.Layout.settingsNamesIndent)
        }
    }

    /// "example-org/api-service · staging · 18 secrets · 7 variables · expires 1 Nov, 14:02".
    private var detail: String {
        let parts = entry.repositories + entry.stages
            + [ProjectShareCopy.counts(entry.counts), ProjectShareCopy.sentExpiry(entry.expiresAt, isExpired: entry.isExpired)]
            + [entry.recipients].compactMap(\.self)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ForEach(entry.places) { place in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: place.title)
                        .fxTextStyle(.formLabel)
                        .foregroundStyle(Theme.Colors.subtleText)
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                        ForEach(place.names) { name in
                            Text(verbatim: name.name)
                                .font(Theme.Typography.monoLabel)
                                .foregroundStyle(name.kind == .secret ? Theme.Colors.ink : Theme.Colors.mutedText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(.top, Theme.Spacing.xSmall)
    }

    private static let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.medium, alignment: .leading),
        GridItem(.flexible(), spacing: Theme.Spacing.medium, alignment: .leading),
    ]
}

/// "▸ Show names": an 11 pt ink link with a small triangle.
private struct SentShareDisclosureLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            configuration.icon
                .imageScale(.small)
                .font(Theme.Typography.label)
            configuration.title
                .fxTextStyle(.formNote)
        }
        .foregroundStyle(Theme.Colors.ink)
        .contentShape(.rect)
    }
}
