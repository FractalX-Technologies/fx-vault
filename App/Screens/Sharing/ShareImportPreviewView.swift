import SharingKit
import SwiftUI
import VaultCore

/// The import preview (§9.5), shared by `ShareImportScreen` and `NearbyReceiveScreen`: chips,
/// per-item choices, "Overwrite all", "Deployment branches differ" rows with the widening
/// warning and its second confirmation, and the replay warning. Values are never shown.
struct ShareImportPreviewView: View {
    let editor: ShareImportPlanEditor

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ShareNoteView(
                systemImage: "person.crop.circle.badge.questionmark",
                text: origin
            )
            if editor.plan.requiresReplayConfirmation {
                replayWarning
            }
            List {
                ForEach(editor.sections) { section in
                    Section {
                        if let environment = section.environment {
                            environmentRows(environment)
                        }
                        ForEach(section.items) { item in
                            ShareImportItemRow(item: item) { action in
                                editor.select(action, for: item)
                            }
                        }
                    } header: {
                        Text(verbatim: section.environment?.name
                            ?? String(localized: "share.preview.repositoryLevel", defaultValue: "Repository"))
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: Theme.Layout.shareListHeight)
            HStack {
                Text(String(
                    localized: "share.preview.summary",
                    defaultValue: "\(editor.changedCount) changes, \(editor.pendingChangeCount) pending until you Sync"
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                if editor.hasDifferingItems {
                    Button(String(localized: "share.preview.overwriteAll", defaultValue: "Overwrite All")) {
                        editor.overwriteAll()
                    }
                    .disabled(editor.isOverwritingAll)
                    .help(String(
                        localized: "share.preview.overwriteAll.help",
                        defaultValue: "Replace every value that differs with the incoming one."
                    ))
                }
            }
        }
        .confirmationDialog(
            String(localized: "share.preview.widening.title", defaultValue: "Allow deployments from more branches?"),
            isPresented: Binding(
                get: { editor.pendingWideningEnvironment != nil },
                set: { if !$0 { editor.cancelWidening() } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "share.preview.widening.confirm", defaultValue: "Use Incoming Policy"),
                role: .destructive
            ) {
                editor.confirmWidening()
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                editor.cancelWidening()
            }
        } message: {
            Text(String(
                localized: "share.preview.widening.message",
                defaultValue: "The incoming policy lets more branches or tags deploy to \(editor.pendingWidening?.name ?? ""), so they can read its secrets. Only accept it if you expected this change."
            ))
        }
    }

    private var origin: String {
        if let sender = editor.senderName, !sender.isEmpty {
            return String(
                localized: "share.preview.origin",
                defaultValue: "From \(sender) (unverified) for \(editor.repositoryFullName)"
            )
        }
        return String(
            localized: "share.preview.origin.unknown",
            defaultValue: "For \(editor.repositoryFullName). The sender is not verified."
        )
    }

    private var replayWarning: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
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
        }
    }

    @ViewBuilder
    private func environmentRows(_ environment: ShareEnvironmentPlanModel) -> some View {
        switch environment.action {
        case .create(let pending):
            ShareNoteView(
                systemImage: "plus.square.on.square",
                text: pending
                    ? String(localized: "share.preview.env.create", defaultValue: "Creates this environment (pending until Sync)")
                    : String(localized: "share.preview.env.createSynced", defaultValue: "Adds this environment, which GitHub already has")
            )
        case .blockedDeletedLocally:
            ShareNoteView(
                systemImage: "trash",
                text: String(
                    localized: "share.preview.env.deleted",
                    defaultValue: "Deleted in your vault and waiting for Sync. Nothing in it is imported."
                ),
                tint: Theme.Colors.danger
            )
        case .useExisting:
            EmptyView()
        }
        if let difference = environment.policyDifference {
            SharePolicyDifferenceRow(difference: difference) { decision in
                editor.choosePolicy(decision, for: environment)
            }
        }
    }
}

/// One incoming item: name, kind, chip, warnings and the action picker.
private struct ShareImportItemRow: View {
    let item: ShareItemPlanModel
    let onSelect: (ShareItemAction) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: item.key.kind == .secret ? "key" : "textformat")
                .foregroundStyle(Theme.Colors.textSecondary)
                .accessibilityLabel(item.key.kind == .secret
                    ? String(localized: "share.preview.kind.secret", defaultValue: "Secret")
                    : String(localized: "share.preview.kind.variable", defaultValue: "Variable"))
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: item.key.name)
                    .font(Theme.Typography.monospaced)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                ForEach(Array(item.warnings).sorted { $0.rawValue < $1.rawValue }, id: \.self) { warning in
                    Text(warning.localizedMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.warning)
                }
            }
            Spacer(minLength: Theme.Spacing.small)
            item.chip.chip
            if item.allowedActions.count > 1 {
                Picker(
                    String(localized: "share.preview.action", defaultValue: "Action"),
                    selection: Binding(get: { item.action }, set: { onSelect($0) })
                ) {
                    ForEach(item.allowedActions, id: \.self) { action in
                        Text(action.localizedTitle).tag(action)
                    }
                }
                .labelsHidden()
                .frame(width: Theme.Layout.shareActionPickerWidth)
            } else {
                Text(item.action.localizedTitle)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: Theme.Layout.shareActionPickerWidth, alignment: .leading)
            }
        }
    }
}

/// "Deployment branches differ" (§9.5): Keep mine by default; a widening incoming policy is
/// marked and needs a second confirmation.
private struct SharePolicyDifferenceRow: View {
    let difference: SharePolicyDifferenceModel
    let onChoose: (SharePolicyDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack {
                Label(
                    String(localized: "share.preview.policy.title", defaultValue: "Deployment branches differ"),
                    systemImage: "arrow.triangle.branch"
                )
                .font(Theme.Typography.callout.weight(.semibold))
                Spacer()
                Picker(
                    String(localized: "share.preview.policy.choice", defaultValue: "Policy"),
                    selection: Binding(get: { difference.decision }, set: { onChoose($0) })
                ) {
                    Text(String(localized: "share.preview.policy.keepMine", defaultValue: "Keep mine"))
                        .tag(SharePolicyDecision.keepMine)
                    Text(String(localized: "share.preview.policy.useIncoming", defaultValue: "Use incoming"))
                        .tag(SharePolicyDecision.useIncoming)
                }
                .labelsHidden()
                .frame(width: Theme.Layout.shareActionPickerWidth)
            }
            Text(String(
                localized: "share.preview.policy.mine",
                defaultValue: "Yours: \(difference.localPolicy.localizedSummary)"
            ))
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            Text(String(
                localized: "share.preview.policy.incoming",
                defaultValue: "Incoming: \(difference.incomingPolicy.localizedSummary)"
            ))
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            ForEach(difference.incomingPolicy.localizedPatterns, id: \.self) { pattern in
                Text(verbatim: pattern)
                    .font(Theme.Typography.caption.monospaced())
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            if difference.isWidening {
                ShareNoteView(
                    systemImage: "exclamationmark.shield",
                    text: String(
                        localized: "share.preview.policy.widening",
                        defaultValue: "The incoming policy allows deployments from more branches. Accepting it needs a second confirmation."
                    ),
                    tint: Theme.Colors.danger
                )
            }
        }
        .padding(.vertical, Theme.Spacing.xSmall)
    }
}
