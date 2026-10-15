import SwiftUI

/// Step 1 (§7.2): per repository and scope what will change (names only), blocked changes with
/// their fixes, changes routed to Drift review, credential-looking variables and the write limit.
struct SyncSummaryView: View {
    @Bindable var viewModel: SyncViewModel

    var body: some View {
        Form {
            if viewModel.executableCount == 0 {
                Section {
                    SyncNoteRow(
                        text: String(
                            localized: "sync.summary.nothingToRun",
                            defaultValue: "Nothing can be synced right now. Fix the blocked changes below, then sync again."
                        ),
                        systemImage: "info.circle"
                    )
                }
            }
            ForEach(viewModel.repositories) { repository in
                Section {
                    repositoryRows(repository)
                } header: {
                    Text(verbatim: repository.fullName)
                        .font(Theme.Typography.headline)
                }
            }
            if !viewModel.credentialRows.isEmpty {
                credentialSection
            }
            limitSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func repositoryRows(_ repository: SyncSummaryRepoModel) -> some View {
        if let newRepository = repository.newRepository {
            SyncNoteRow(text: newRepository, systemImage: "plus.rectangle.on.folder", tint: Theme.Colors.pending)
        }
        ForEach(repository.scopes) { scope in
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: scope.sentence)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                if !scope.details.isEmpty {
                    Text(verbatim: scope.details.joined(separator: "   "))
                        .font(Theme.Typography.caption.monospaced())
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        ForEach(repository.blocked) { issue in
            SyncIssueRow(issue: issue, systemImage: "nosign", tint: Theme.Colors.danger) { viewModel.perform($0) }
        }
        if repository.dependentCount > 0 {
            SyncNoteRow(
                text: String(
                    localized: "sync.summary.dependents",
                    defaultValue: "\(repository.dependentCount) more changes wait for the blocked ones."
                ),
                systemImage: "arrow.turn.down.right"
            )
        }
        ForEach(repository.remoteChanged) { issue in
            SyncIssueRow(
                issue: issue,
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                tint: Theme.Colors.warning
            ) { viewModel.perform($0) }
        }
        ForEach(repository.notes, id: \.self) { note in
            SyncNoteRow(text: note, systemImage: "info.circle")
        }
    }

    private var credentialSection: some View {
        Section {
            ForEach(viewModel.credentialRows) { row in
                SyncIssueRow(
                    issue: SyncIssueModel(id: row.id, title: row.title, reason: row.reasons, fix: row.fix),
                    systemImage: "key",
                    tint: Theme.Colors.warning
                ) { viewModel.perform($0) }
            }
            Toggle(
                String(localized: "sync.credential.confirm", defaultValue: "Push these as variables anyway"),
                isOn: $viewModel.credentialsConfirmed
            )
        } header: {
            Text(String(localized: "sync.credential.header", defaultValue: "Variables that look like credentials"))
        } footer: {
            Text(String(
                localized: "sync.credential.footer",
                defaultValue: "Variable values are visible to anyone who can read the repository's settings or workflow logs. Secrets are not."
            ))
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private var limitSection: some View {
        let warnings = viewModel.summaryWarnings
        if viewModel.writeBudgetLine != nil || viewModel.writeBudgetWarning != nil || !warnings.isEmpty {
            Section {
                if let line = viewModel.writeBudgetLine {
                    SyncNoteRow(text: line, systemImage: "gauge.with.dots.needle.33percent")
                        .help(SyncCopy.writeBudgetHelp)
                }
                if let warning = viewModel.writeBudgetWarning {
                    SyncNoteRow(text: warning, systemImage: "exclamationmark.triangle", tint: Theme.Colors.warning)
                }
                ForEach(warnings, id: \.self) { warning in
                    SyncNoteRow(text: warning, systemImage: "exclamationmark.triangle", tint: Theme.Colors.warning)
                }
            }
        }
    }
}
