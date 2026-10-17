import SharingKit
import SwiftUI
import VaultCore

/// The import preview (§9.5), shared by `ShareImportScreen` and `NearbyReceiveScreen`: chips,
/// per-item choices, "Overwrite all", "Deployment branches differ" rows with the widening
/// warning and its second confirmation, and the replay warning. Values are never shown.
struct ShareImportPreviewView: View {
    let editor: ShareImportPlanEditor
    /// False inside a project share's preview (v0.9.0), which shows the sender, the replay
    /// warning and the totals once for the whole file.
    var isStandalone = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if isStandalone {
                ShareNoteView(
                    systemImage: "person.crop.circle.badge.questionmark",
                    text: origin
                )
                if editor.plan.requiresReplayConfirmation {
                    replayWarning
                }
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
                            .listRowSeparator(.visible)
                            .listRowSeparatorTint(Theme.Colors.hairline)
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                            Text(verbatim: section.environment?.name
                                ?? String(localized: "share.preview.repositoryLevel", defaultValue: "Repository"))
                                .fxTextStyle(.sectionLabel)
                                .foregroundStyle(Theme.Colors.ink)
                            Text(ShareSummaryLineModel.counts(section.counts))
                                .fxTextStyle(.monoMeta)
                                .foregroundStyle(Theme.Colors.subtleText)
                        }
                    }
                }
            }
            .shareListContainer()
            .frame(height: isStandalone ? Theme.Layout.shareListHeight : Theme.Layout.shareListMinHeight)
            HStack(spacing: Theme.Spacing.medium) {
                if isStandalone {
                    Text(String(
                        localized: "share.preview.summary",
                        defaultValue: "\(editor.changedCount) changes, \(editor.pendingChangeCount) pending until you Sync"
                    ))
                    .fxTextStyle(.statusLine)
                    .foregroundStyle(Theme.Colors.subtleText)
                }
                Spacer()
                if editor.hasDifferingItems {
                    Button(String(localized: "share.preview.overwriteAll", defaultValue: "Overwrite All")) {
                        editor.overwriteAll()
                    }
                    .fxButtonStyle(.outline)
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

    @ViewBuilder
    private func environmentRows(_ environment: ShareEnvironmentPlanModel) -> some View {
        switch environment.action {
        case .create(let pending) where environment.includesBranchPolicy:
            ShareNoteView(
                systemImage: "plus.square.on.square",
                text: pending
                    ? String(localized: "share.preview.env.create", defaultValue: "Creates this environment (pending until Sync)")
                    : String(localized: "share.preview.env.createSynced", defaultValue: "Adds this environment, which GitHub already has")
            )
        case .create where !environment.createsEnvironment:
            ShareNoteView(
                systemImage: "minus.square",
                text: String(
                    localized: "share.preview.env.notCreated",
                    defaultValue: "Not created: none of its items is selected."
                )
            )
        case .create(let pending):
            ShareNoteView(
                systemImage: "plus.square.on.square",
                text: pending
                    ? String(
                        localized: "share.preview.env.createPartial",
                        defaultValue: "Creates this environment with all branches allowed (pending until Sync). The share includes only some of its items, not its branch policy."
                    )
                    : String(
                        localized: "share.preview.env.createPartialSynced",
                        defaultValue: "Adds this environment with the branch policy GitHub already has. The share includes only some of its items."
                    )
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
        case .useExisting where !environment.includesBranchPolicy:
            ShareNoteView(
                systemImage: "arrow.triangle.branch",
                text: String(
                    localized: "share.preview.env.partial",
                    defaultValue: "Only some items of this environment are shared. Your branch policy stays as it is."
                )
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

/// One incoming item of the GitHub scopes.
private struct ShareImportItemRow: View {
    let item: ShareItemPlanModel
    let onSelect: (ShareItemAction) -> Void

    var body: some View {
        ShareImportActionRow(
            kind: item.key.kind,
            name: item.key.name,
            warnings: item.warnings,
            chip: item.chip,
            allowedActions: item.allowedActions,
            action: item.action,
            onSelect: onSelect
        )
    }
}

/// One incoming item: name, kind, chip, warnings and the action picker (GitHub scopes, and a
/// project share's destinations, v0.9.0).
struct ShareImportActionRow: View {
    let kind: ConfigKind
    let name: String
    let warnings: Set<ShareItemWarning>
    let chip: ShareItemChip
    let allowedActions: [ShareItemAction]
    let action: ShareItemAction
    let onSelect: (ShareItemAction) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: kind == .secret ? "key" : "textformat")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityLabel(kind == .secret
                    ? String(localized: "share.preview.kind.secret", defaultValue: "Secret")
                    : String(localized: "share.preview.kind.variable", defaultValue: "Variable"))
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                TableNameText(name: name)
                ForEach(Array(warnings).sorted { $0.rawValue < $1.rawValue }, id: \.self) { warning in
                    Text(warning.localizedMessage)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.warning)
                }
            }
            Spacer(minLength: Theme.Spacing.small)
            chip.chip
            if allowedActions.count > 1 {
                Picker(
                    String(localized: "share.preview.action", defaultValue: "Action"),
                    selection: Binding(get: { action }, set: { onSelect($0) })
                ) {
                    ForEach(allowedActions, id: \.self) { action in
                        Text(action.localizedTitle).tag(action)
                    }
                }
                .labelsHidden()
                .frame(width: Theme.Layout.shareActionPickerWidth)
            } else {
                Text(action.localizedTitle)
                    .fxTextStyle(.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .frame(width: Theme.Layout.shareActionPickerWidth, alignment: .leading)
            }
        }
        .frame(minHeight: Theme.Layout.scopeRowHeight)
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
                .fxTextStyle(.calloutEmphasized)
                .foregroundStyle(Theme.Colors.ink)
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
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            Text(String(
                localized: "share.preview.policy.incoming",
                defaultValue: "Incoming: \(difference.incomingPolicy.localizedSummary)"
            ))
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            ForEach(difference.incomingPolicy.localizedPatterns, id: \.self) { pattern in
                TableMetaText(pattern)
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

/// The one-click "Import <owner/name> from GitHub" of a share import preview (§9.5), shared by
/// the file import, nearby receive and chat save sheets. It runs gh, so it is disabled offline
/// and says why.
struct ShareImportRepositoryButton: View {
    let title: String
    let isImporting: Bool
    let isOnline: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack(spacing: Theme.Spacing.small) {
                Button(title, action: action)
                    .fxButtonStyle(.outline)
                    .disabled(isImporting || !isOnline)
                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if !isOnline {
                Text(ConnectivityCopy.offlineHelp)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
