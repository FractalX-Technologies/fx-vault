import SwiftUI

/// Step 1 (§7.2): per repository and scope what will change (names only), blocked changes with
/// their fixes, changes routed to Drift review, the From Files review of rows held by share files
/// (v0.9.0), credential-looking variables, "What changed?" when the run publishes shared versions
/// (v0.6.0), and the write limit.
///
/// Board SyncReview: each repository is a hairline card of scope rows (mono scope label, the
/// counts sentence, the mono names); confirmations are checkbox rows.
struct SyncSummaryView: View {
    @Bindable var viewModel: SyncViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                if viewModel.waitsOnlyForHeldShares {
                    Banner(.info, message: HeldShareCopy.onlyHeld, systemImage: "info.circle")
                } else if viewModel.executableCount == 0 {
                    Banner(
                        .warning,
                        message: String(
                            localized: "sync.summary.nothingToRun",
                            defaultValue: "Nothing can be synced right now. Fix the blocked changes below, then sync again."
                        ),
                        systemImage: "info.circle"
                    )
                }
                ForEach(viewModel.repositories.filter(\.hasContent)) { repository in
                    SyncSummaryRepositoryView(repository: repository, showsName: viewModel.repositories.count > 1) {
                        viewModel.perform($0)
                    }
                }
                if !viewModel.heldShares.isEmpty {
                    SyncHeldSharesView(rows: viewModel.heldShareRows) { packageID, isIncluded in
                        viewModel.setIncluded(packageID, isIncluded)
                    }
                }
                if !viewModel.credentialRows.isEmpty {
                    credentialSection
                }
                if viewModel.publishesSharedVersions {
                    FXTextField(
                        label: SyncCopy.spaceReasonTitle,
                        text: $viewModel.spaceReason,
                        prompt: SyncCopy.spaceReasonPlaceholder
                    )
                }
                limitSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.xxLarge)
            .padding(.bottom, Theme.Spacing.xLarge)
        }
    }

    private var credentialSection: some View {
        ConfigSheetField(String(localized: "sync.credential.header", defaultValue: "Variables that look like credentials")) {
            ConfigSheetList(viewModel.credentialRows) { row in
                SyncIssueRow(
                    issue: SyncIssueModel(id: row.id, title: row.title, reason: row.reasons, fix: row.fix),
                    systemImage: "key",
                    tint: Theme.Colors.warning
                ) { viewModel.perform($0) }
            }
            FXCheckboxRow(
                title: String(localized: "sync.credential.confirm", defaultValue: "Push these as variables anyway"),
                isOn: $viewModel.credentialsConfirmed
            )
            Text(String(
                localized: "sync.credential.footer",
                defaultValue: "Variable values are visible to anyone who can read the repository's settings or workflow logs. Secrets are not."
            ))
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.subtleText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Warnings about the run as a whole. The write limit itself is footer meta; it moves here
    /// only while the footer shows a notice instead (offline).
    @ViewBuilder
    private var limitSection: some View {
        let warnings = viewModel.summaryWarnings
        let showsLine = viewModel.footerNotice != nil ? viewModel.writeBudgetLine : nil
        if showsLine != nil || viewModel.writeBudgetWarning != nil || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if let line = showsLine {
                    SyncNoteRow(text: line, systemImage: "gauge.with.dots.needle.33percent")
                        .help(SyncCopy.writeBudgetHelp)
                }
                if let warning = viewModel.writeBudgetWarning {
                    Banner(.warning, message: warning)
                }
                ForEach(warnings, id: \.self) { warning in
                    Banner(.warning, message: warning)
                }
            }
        }
    }
}

/// One repository of the summary: its scope card, then blocked and drift-routed changes, then
/// notes. The name heads the block only when the run spans several repositories (otherwise it is
/// in the sheet title).
private struct SyncSummaryRepositoryView: View {
    let repository: SyncSummaryRepoModel
    let showsName: Bool
    let onFix: (SyncFixActionModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
            if showsName {
                Text(verbatim: repository.fullName)
                    .fxTextStyle(.monoName)
                    .foregroundStyle(Theme.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            if let newRepository = repository.newRepository {
                SyncNoteRow(text: newRepository, systemImage: "plus.rectangle.on.folder", tint: Theme.Colors.brand)
            }
            if !repository.scopes.isEmpty {
                SyncScopeGrid(scopes: repository.scopes)
            }
            if !repository.blocked.isEmpty || !repository.remoteChanged.isEmpty {
                ConfigSheetList(issues) { entry in
                    SyncIssueRow(issue: entry.issue, systemImage: entry.systemImage, tint: entry.tint, onFix: onFix)
                }
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
            ForEach(repository.notes, id: \.self) { note in
                SyncNoteRow(text: note, systemImage: "info.circle")
            }
        }
    }

    /// Blocked changes first, then the ones routed to Drift review.
    private var issues: [SyncIssueEntry] {
        repository.blocked.map { SyncIssueEntry(issue: $0, systemImage: "nosign", tint: Theme.Colors.danger) }
            + repository.remoteChanged.map {
                SyncIssueEntry(issue: $0, systemImage: "exclamationmark.arrow.triangle.2.circlepath", tint: Theme.Colors.warning)
            }
    }
}

/// An issue with its symbol, for a mixed ``ConfigSheetList``.
private struct SyncIssueEntry: Identifiable {
    let issue: SyncIssueModel
    let systemImage: String
    let tint: Color

    var id: String { "\(systemImage)|\(issue.id)" }
}

/// The scope rows of one repository (board SyncReview): mono uppercase scope label on the left,
/// the counts sentence and the mono names on the right, a hairline between rows.
private struct SyncScopeGrid: View {
    let scopes: [SyncSummaryScopeModel]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.large, verticalSpacing: 0) {
            ForEach(Array(scopes.enumerated()), id: \.element.id) { index, scope in
                if index > 0 {
                    HairlineDivider()
                }
                GridRow {
                    Text(verbatim: scope.title)
                        .textCase(.uppercase)
                        .fxTextStyle(.monoCounter)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .lineLimit(2)
                        .padding(.leading, Theme.Spacing.large)
                        .padding(.vertical, Theme.Spacing.medium)
                    VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
                        Text(verbatim: scope.sentence)
                            .fxTextStyle(.bodyEmphasized)
                            .foregroundStyle(Theme.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if !scope.details.isEmpty {
                            Text(verbatim: scope.details.joined(separator: "   "))
                                .fxTextStyle(.monoMeta)
                                .foregroundStyle(Theme.Colors.mutedText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, Theme.Spacing.large)
                    .padding(.vertical, Theme.Spacing.medium)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .fxCardBackground(.container)
    }
}
