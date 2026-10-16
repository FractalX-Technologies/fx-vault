import SwiftUI
import VaultCore

/// Preferences › Teammates (v0.5.0): Who can see me, Mute all pings, the paired devices (Mute,
/// Remove…) and Add Teammate….
struct TeammatesSettingsScreen: View {
    @Bindable var viewModel: TeammatesSettingsViewModel

    var body: some View {
        PreferencesPage {
            PreferencesSection(
                String(localized: "settings.teammates.visibility.section", defaultValue: "Nearby"),
                footnote: viewModel.visibility.explanation
            ) {
                PreferencesRow(String(localized: "settings.teammates.visibility", defaultValue: "Who can see this Mac")) {
                    Picker(String(localized: "settings.teammates.visibility", defaultValue: "Who can see this Mac"), selection: $viewModel.visibility) {
                        ForEach(NearbyVisibility.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HairlineDivider()
                PreferencesRow(
                    String(localized: "settings.teammates.muteAll", defaultValue: "Mute all pings"),
                    detail: String(
                        localized: "settings.teammates.muteAll.detail",
                        defaultValue: "A ping still bounces the bubble, without a sound or a notification."
                    )
                ) {
                    Toggle(String(localized: "settings.teammates.muteAll", defaultValue: "Mute all pings"), isOn: $viewModel.mutesAllPings)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            PreferencesSection(
                String(localized: "settings.teammates.section", defaultValue: "Teammates"),
                footnote: String(
                    localized: "settings.teammates.footnote",
                    defaultValue: "Teammates are Macs you paired with by comparing a code. They recognize each other nearby, can ping each other and chat without a code."
                )
            ) {
                if viewModel.teammates.isEmpty {
                    PreferencesBlock {
                        Text(String(
                            localized: "settings.teammates.empty",
                            defaultValue: "No teammates yet. Open Add Teammate on both Macs, side by side."
                        ))
                        .fxTextStyle(.body)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(viewModel.teammates.enumerated()), id: \.element.id) { index, teammate in
                    if index > 0 {
                        HairlineDivider()
                    }
                    TeammateRow(teammate: teammate, viewModel: viewModel)
                }
                HairlineDivider()
                PreferencesBlock {
                    Button(String(localized: "settings.teammates.add", defaultValue: "Add Teammate…")) {
                        viewModel.startAddingTeammate()
                    }
                    .fxButtonStyle(.outline)
                    .disabled(!viewModel.isUnlocked)
                    if !viewModel.isUnlocked {
                        Text(String(localized: "settings.teammates.locked", defaultValue: "Unlock FX Vault to add or remove teammates."))
                            .fxTextStyle(.caption)
                            .foregroundStyle(Theme.Colors.mutedText)
                    }
                }
            }
            if !viewModel.teammates.isEmpty {
                RemoteTeammatesSection(viewModel: viewModel)
            }
        }
        .sheet(item: $viewModel.addTeammate, onDismiss: viewModel.addTeammateDismissed) { model in
            AddTeammateSheet(viewModel: model)
        }
        .confirmationDialog(
            String(localized: "settings.teammates.remove.title", defaultValue: "Remove \(viewModel.pendingRemoval?.name ?? "")?"),
            isPresented: removalBinding,
            titleVisibility: .visible,
            presenting: viewModel.pendingRemoval
        ) { _ in
            Button(String(localized: "settings.teammates.remove.confirm", defaultValue: "Remove Teammate"), role: .destructive) {
                viewModel.confirmRemoval()
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                viewModel.pendingRemoval = nil
            }
        } message: { _ in
            Text(String(
                localized: "settings.teammates.remove.message",
                defaultValue: "Their Mac will no longer recognize this one: FX Vault changes the name this Mac uses nearby. Your other teammates get the new one the next time they are nearby."
            ))
        }
        .errorAlert($viewModel.alert)
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingRemoval != nil },
            set: { if !$0 { viewModel.pendingRemoval = nil } }
        )
    }
}

/// One teammate: name, login and Mac, last seen, Mute and Remove….
private struct TeammateRow: View {
    let teammate: TeammateModel
    let viewModel: TeammatesSettingsViewModel

    var body: some View {
        PreferencesBlock {
            row
        }
    }

    private var row: some View {
        HStack(spacing: Theme.Spacing.medium) {
            NearbyAvatar(person: NearbyPersonModel(
                kind: .teammate(deviceID: teammate.id),
                name: teammate.name,
                macName: teammate.macName,
                lastSeenAt: teammate.lastSeenAt ?? teammate.pairedAt
            ))
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: teammate.name)
                    .fxTextStyle(.body)
                    .foregroundStyle(Theme.Colors.ink)
                Text(verbatim: [teammate.login, teammate.macName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                Text(viewModel.lastSeenText(teammate))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(
                String(localized: "settings.teammates.mute", defaultValue: "Mute"),
                isOn: Binding(get: { teammate.isMuted }, set: { viewModel.setMuted($0, teammate) })
            )
            .toggleStyle(.checkbox)
            Button(String(localized: "settings.teammates.remove", defaultValue: "Remove…")) {
                viewModel.pendingRemoval = teammate
            }
            .fxButtonStyle(.outline)
            .disabled(!viewModel.isUnlocked)
        }
    }
}

/// Outside this network (v0.6.0, Q4): the listener port, then per teammate the switch, its
/// address and the last sync there.
private struct RemoteTeammatesSection: View {
    @Bindable var viewModel: TeammatesSettingsViewModel

    var body: some View {
        PreferencesSection(TeammatesCopy.remoteSection, footnote: TeammatesCopy.remoteFootnote(port: UInt16(viewModel.portText) ?? 0)) {
            if let failure = viewModel.remoteFailureText {
                PreferencesBlock {
                    Banner(.warning, message: failure)
                }
                HairlineDivider()
            }
            PreferencesRow(TeammatesCopy.port) {
                TextField(TeammatesCopy.port, text: $viewModel.portText)
                    .labelsHidden()
                    .frame(width: Theme.Layout.portFieldWidth)
                    .onSubmit { viewModel.commitPort() }
            }
            ForEach(viewModel.teammates) { teammate in
                HairlineDivider()
                PreferencesRow(teammate.name, detail: viewModel.remoteSummary(teammate) ?? TeammatesCopy.allow) {
                    Toggle(TeammatesCopy.allow, isOn: Binding(
                        get: { viewModel.isRemoteAllowed(teammate) },
                        set: { viewModel.setRemoteAllowed($0, teammate) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                if viewModel.isRemoteAllowed(teammate) {
                    PreferencesBlock {
                        FXTextField(
                            label: TeammatesCopy.address,
                            text: Binding(
                                get: { viewModel.addressDrafts[teammate.id] ?? "" },
                                set: { viewModel.addressDrafts[teammate.id] = $0 }
                            ),
                            prompt: TeammatesCopy.addressPrompt,
                            isMonospaced: true
                        )
                        .onSubmit { viewModel.commitAddress(teammate) }
                    }
                }
            }
        }
    }
}
