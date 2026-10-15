import SwiftUI

/// Step 4 (§7.4): Failed / Blocked / Skipped / Succeeded with reasons and fixes, the stop
/// reason, warnings and the clones the run requested.
struct SyncResultView: View {
    let viewModel: SyncViewModel

    var body: some View {
        Form {
            if let stop = viewModel.stopReason {
                Section {
                    SyncIssueRow(issue: stop, systemImage: "pause.circle", tint: Theme.Colors.warning) {
                        viewModel.perform($0)
                    }
                }
            }
            if !viewModel.clones.isEmpty {
                Section(String(localized: "sync.result.clones", defaultValue: "Clones")) {
                    ForEach(viewModel.clones) { clone in
                        SyncCloneRow(row: clone, fix: viewModel.cloneFix(clone)) { viewModel.perform($0) }
                    }
                }
            }
            ForEach(viewModel.resultSections) { section in
                Section {
                    if section.kind == .succeeded {
                        DisclosureGroup(String(
                            localized: "sync.result.succeeded.count",
                            defaultValue: "\(section.rows.count) changes"
                        )) {
                            rows(section)
                        }
                    } else {
                        rows(section)
                    }
                } header: {
                    Label(section.kind.title, systemImage: section.kind.systemImage)
                        .foregroundStyle(section.kind.tint)
                }
            }
            if !viewModel.warnings.isEmpty {
                Section(String(localized: "sync.result.warnings", defaultValue: "Good to know")) {
                    ForEach(viewModel.warnings, id: \.self) { warning in
                        SyncNoteRow(text: warning, systemImage: "info.circle")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func rows(_ section: SyncResultSectionModel) -> some View {
        ForEach(section.rows) { issue in
            SyncIssueRow(issue: issue, systemImage: section.kind.systemImage, tint: section.kind.tint) {
                viewModel.perform($0)
            }
        }
    }
}

/// One clone the run requested, with a busy state while it runs.
private struct SyncCloneRow: View {
    let row: SyncCloneRowModel
    let fix: SyncFixActionModel?
    let onFix: (SyncFixActionModel) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: row.fullName)
                    .font(Theme.Typography.body)
                Text(verbatim: detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if row.state == .cloning {
                ProgressView()
                    .controlSize(.small)
            } else if let fix {
                Button(SyncCopy.fixTitle(fix)) { onFix(fix) }
                    .controlSize(.small)
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
        case .skipped: Theme.Colors.textSecondary
        }
    }
}
