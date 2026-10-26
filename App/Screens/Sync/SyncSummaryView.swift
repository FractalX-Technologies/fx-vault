import SwiftUI

/// Step 1 (§7.2): one hairline card per place with what will change there (names only), its
/// blocked changes with their fixes and the changes routed to Drift review; then the From Files
/// review of rows held by share files (v0.9.0), credential-looking variables and the write limit.
/// Board Sync-Review; confirmations are checkbox rows.
struct SyncSummaryView: View {
    @Bindable var viewModel: SyncViewModel

    var body: some View {
        ScrollView {
            // 10 pt between cards, as the boards.
            VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
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
                    ForEach(repository.cards) { card in
                        SyncSummaryCardView(card: card) {
                            viewModel.perform($0)
                        }
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
                limitSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Layout.compactSheetInset)
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

    /// The write limit and warnings about the run as a whole (the footer has the counts).
    @ViewBuilder
    private var limitSection: some View {
        let warnings = viewModel.summaryWarnings
        let showsLine = viewModel.writeBudgetLine
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

/// One place of the summary (board Sync-Review): a hairline card headed by its symbol, name and
/// kind; its `+ ~ −` lines, blocked lines with `!` (`↯` when GitHub changed it), their reason
/// and an inline fix, then what waits and the notes.
private struct SyncSummaryCardView: View {
    let card: SyncSummaryCardModel
    let onFix: (SyncFixActionModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SyncPlaceHeader(systemImage: card.place.systemImage, name: card.place.name, kind: card.place.kind)
            if let newRepository = card.newRepository {
                SyncNoteRow(text: newRepository, systemImage: "plus.rectangle.on.folder", tint: Theme.Colors.brand)
            }
            if let sentence = card.sentence {
                Text(verbatim: sentence)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(card.lines, id: \.self) { line in
                SyncChangeLine(line: line)
            }
            ForEach(card.blocked) { issue in
                SyncBlockedLine(issue: issue, symbol: "!", tint: Theme.Colors.ink, onFix: onFix)
            }
            ForEach(card.remoteChanged) { issue in
                SyncBlockedLine(issue: issue, symbol: "↯", tint: Theme.Colors.warning, onFix: onFix)
            }
            if card.dependentCount > 0 {
                SyncNoteRow(
                    text: String(
                        localized: "sync.summary.dependents",
                        defaultValue: "\(card.dependentCount) more changes wait for the blocked ones."
                    ),
                    systemImage: "arrow.turn.down.right"
                )
            }
            ForEach(card.notes, id: \.self) { note in
                SyncNoteRow(text: note, systemImage: "info.circle")
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.mediumMinus)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxDialogCard()
    }
}

/// A card's header (boards Sync-Review, Sync-Progress): the place's symbol, its name in 12 pt
/// semibold and its kind, muted.
struct SyncPlaceHeader: View {
    let systemImage: String
    let name: String
    let kind: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.smallMinus) {
            Image(systemName: systemImage)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .fxTextStyle(.placeName)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: kind)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// `+ FEATURE_FLAGS  variable`: the symbol in its own column, the mono name, the muted detail.
/// A deletion reads red; a line about the place itself (deployment branches) only muted.
private struct SyncChangeLine: View {
    let line: SyncChangeLineModel

    var body: some View {
        let isDeletion = line.symbol == .deleted
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(verbatim: line.symbol?.rawValue ?? "")
                .fxTextStyle(.monoMeta)
                .foregroundStyle(isDeletion ? Theme.Colors.danger : Theme.Colors.ink)
                .frame(width: Theme.Layout.syncSymbolWidth, alignment: .leading)
                .accessibilityHidden(line.symbol == nil)
            if let name = line.name {
                Text(verbatim: name)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(isDeletion ? Theme.Colors.danger : Theme.Colors.ink)
                    .textSelection(.enabled)
            }
            if let detail = line.detail {
                Text(verbatim: detail)
                    .fxTextStyle(.caption)
                    .foregroundStyle(isDeletion ? Theme.Colors.danger : Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// `! DOCKER_PASSWORD` with its reason below and the fix as a link at the trailing edge.
private struct SyncBlockedLine: View {
    let issue: SyncIssueModel
    let symbol: String
    let tint: Color
    let onFix: (SyncFixActionModel) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            // One element read as the full title and the reason ("Add secret DOCKER_PASSWORD in
            // production"); the fix stays outside it so it remains its own button.
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(verbatim: symbol)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(tint)
                    .frame(width: Theme.Layout.syncSymbolWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: issue.name ?? issue.title)
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.ink)
                        .textSelection(.enabled)
                    Text(verbatim: issue.reason)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: issue.title))
            .accessibilityValue(Text(verbatim: issue.reason))
            Spacer(minLength: Theme.Spacing.small)
            if let fix = issue.fix {
                Button(SyncCopy.fixTitle(fix)) {
                    onFix(fix)
                }
                .buttonStyle(FXLinkButtonStyle())
            }
        }
    }
}
