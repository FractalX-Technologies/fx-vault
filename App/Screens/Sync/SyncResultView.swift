import SwiftUI

/// Step 4 (§7.4): Failed / Blocked / Skipped / Succeeded with reasons and fixes, the stop
/// reason, warnings and the clones the run requested.
struct SyncResultView: View {
    let viewModel: SyncViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                if let stop = viewModel.stopReason {
                    SyncIssueRow(issue: stop, systemImage: "pause.circle", tint: Theme.Colors.warning) {
                        viewModel.perform($0)
                    }
                    .configSheetRowPadding()
                    .background(Theme.Colors.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: Theme.Stroke.hairline)
                    )
                }
                if !viewModel.clones.isEmpty {
                    ConfigSheetField(String(localized: "sync.result.clones", defaultValue: "Clones")) {
                        ConfigSheetList(viewModel.clones) { clone in
                            SyncCloneRow(row: clone, fix: viewModel.cloneFix(clone)) { viewModel.perform($0) }
                        }
                    }
                }
                ForEach(viewModel.resultSections) { section in
                    resultSection(section)
                }
                if !viewModel.warnings.isEmpty {
                    ConfigSheetField(String(localized: "sync.result.warnings", defaultValue: "Good to know")) {
                        ForEach(viewModel.warnings, id: \.self) { warning in
                            SyncNoteRow(text: warning, systemImage: "info.circle")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Layout.dialogInset)
        }
    }

    private func resultSection(_ section: SyncResultSectionModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
            HStack(spacing: Theme.Spacing.smallMinus) {
                Image(systemName: section.kind.systemImage)
                    .foregroundStyle(section.kind.tint)
                    .accessibilityHidden(true)
                SectionLabel(section.kind.title)
                if section.kind != .succeeded {
                    Text(verbatim: "\(section.rows.count)")
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .accessibilityHidden(true)
                }
            }
            if section.kind == .succeeded {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(section.rows) { issue in
                            HairlineDivider()
                            row(issue, in: section)
                                .configSheetRowPadding()
                        }
                    }
                } label: {
                    Text(String(
                        localized: "sync.result.succeeded.count",
                        defaultValue: "\(section.rows.count) changes"
                    ))
                    .fxTextStyle(.callout)
                    .foregroundStyle(Theme.Colors.ink)
                }
                .padding(.vertical, Theme.Spacing.small)
                .padding(.horizontal, Theme.Spacing.large)
                .fxCardBackground(.container)
            } else {
                ConfigSheetList(section.rows) { issue in
                    row(issue, in: section)
                }
            }
        }
    }

    private func row(_ issue: SyncIssueModel, in section: SyncResultSectionModel) -> some View {
        SyncIssueRow(issue: issue, systemImage: section.kind.systemImage, tint: section.kind.tint) {
            viewModel.perform($0)
        }
    }
}

/// The finish when nothing failed (board Sync-Done): a green check ring, "Synced 8 changes", the
/// places, what stays pending with its reason, and Done. Narrow and centered.
struct SyncDoneView: View {
    let done: SyncDoneModel
    let onDone: () -> Void

    /// Past this many, the rest is one "and N more" line.
    private static let pendingLimit = 3

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            VStack(spacing: Theme.Spacing.mediumMinus) {
                Image(systemName: "checkmark")
                    .font(Theme.Typography.title2)
                    .foregroundStyle(Theme.Colors.success)
                    .frame(width: Theme.Layout.syncDoneMarkSize, height: Theme.Layout.syncDoneMarkSize)
                    .overlay(RingDot(color: Theme.Colors.success, size: Theme.Layout.syncDoneMarkSize))
                    .accessibilityHidden(true)
                Text(verbatim: SyncCopy.doneTitle(count: done.syncedCount))
                    .fxTextStyle(.leadEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                if !done.places.isEmpty {
                    centered(SyncCopy.donePlaces(done.places), color: Theme.Colors.subtleText)
                }
                ForEach(done.pending.prefix(Self.pendingLimit)) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.smallMinus) {
                        RingDot()
                        Text(verbatim: SyncCopy.donePending(issue))
                            .fxTextStyle(.caption)
                            .foregroundStyle(Theme.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if done.pending.count > Self.pendingLimit {
                    centered(SyncCopy.donePendingMore(done.pending.count - Self.pendingLimit), color: Theme.Colors.mutedText)
                }
                ForEach(done.warnings, id: \.self) { warning in
                    centered(warning, color: Theme.Colors.mutedText)
                }
            }
            .padding(.top, Theme.Spacing.small)
            .padding(.bottom, Theme.Spacing.xSmall)
            Button(String(localized: "common.done", defaultValue: "Done"), action: onDone)
                .fxButtonStyle(.primary, size: .dialog)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Layout.dialogInset)
        .frame(width: Theme.Layout.syncDoneWidth)
    }

    private func centered(_ text: String, color: Color) -> some View {
        Text(verbatim: text)
            .fxTextStyle(.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One clone the run requested, with a busy state while it runs.
private struct SyncCloneRow: View {
    let row: SyncCloneRowModel
    let fix: SyncFixActionModel?
    let onFix: (SyncFixActionModel) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(verbatim: row.fullName)
                    .fxTextStyle(.monoName)
                    .foregroundStyle(Theme.Colors.ink)
                Text(verbatim: detail)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if row.state == .cloning {
                ProgressView()
                    .controlSize(.small)
            } else if let fix {
                Button(SyncCopy.fixTitle(fix)) { onFix(fix) }
                    .fxButtonStyle(.outline)
            }
        }
    }

    private var detail: String {
        switch row.state {
        case .cloning:
            String(localized: "sync.clone.cloning", defaultValue: "Cloning…")
        case .cloned(let path):
            String(localized: "sync.clone.cloned", defaultValue: "Cloned to \(path)")
        case .failed(let message):
            message
        case .notAttempted:
            String(
                localized: "sync.clone.notAttempted",
                defaultValue: "Not cloned: no clone folder is set. Choose one in Settings › General, then clone it."
            )
        }
    }
}

extension SyncResultSectionModel.Kind {
    var systemImage: String {
        switch self {
        case .succeeded: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .skipped: "arrow.uturn.right.circle"
        case .blocked: "nosign"
        }
    }

    var tint: Color {
        switch self {
        case .succeeded: Theme.Colors.success
        case .failed, .blocked: Theme.Colors.danger
        case .skipped: Theme.Colors.subtleText
        }
    }
}
