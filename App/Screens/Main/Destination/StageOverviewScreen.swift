import EnvTools
import SwiftUI
import VaultCore
import VaultData

/// Column 3 while Overview is selected (v0.8.0, canvas board 1): STAGE · ALL DESTINATIONS, the
/// stage with its tags and picker, the `fxvault.yml` check banner, the matrix (names × GitHub and
/// the stage's destinations), the legend, and the manifest panel (parse issues, findings,
/// `.env.example` and a generated `fxvault.yml` to copy).
struct StageOverviewScreen: View {
    @Bindable var viewModel: StageOverviewViewModel
    let main: MainViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.largePlus) {
                if let banner = main.connectivityBanner {
                    MainConnectivityBanner(banner: banner, main: main)
                }
                OverviewHeader(viewModel: viewModel)
                if let overview = viewModel.overview {
                    OverviewFindingsBanner(viewModel: viewModel, overview: overview)
                    OverviewMatrix(viewModel: viewModel, overview: overview)
                    Text(StageOverviewCopy.legend)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                    if viewModel.showsManifestPanel {
                        OverviewManifestPanel(viewModel: viewModel, overview: overview)
                    }
                } else {
                    EmptyStateView(
                        systemImage: "square.grid.2x2",
                        title: StageOverviewCopy.manifestState(viewModel.manifestState, isReading: viewModel.isReadingManifest),
                        message: StageOverviewCopy.noStages
                    )
                }
                if let notice = viewModel.notice {
                    Text(notice)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                }
            }
            .padding(.horizontal, Theme.Spacing.xxLargePlus)
            .padding(.vertical, Theme.Spacing.xLargePlus)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .errorAlert($viewModel.alert)
    }
}

/// The eyebrow, the stage in the large title, the tags, the stage picker and the manifest actions.
private struct OverviewHeader: View {
    @Bindable var viewModel: StageOverviewViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.large) {
                details
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                details
                actions
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            HStack(spacing: Theme.Spacing.smallMinus) {
                SectionLabel(StageOverviewCopy.eyebrow)
                StatusChip.tag(DestinationCopy.experimentalTag)
                    .help(DestinationCopy.experimentalHelp)
            }
            Text(verbatim: viewModel.stage ?? DestinationCopy.overviewTitle)
                .fxTextStyle(.largeTitle)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
            HStack(spacing: Theme.Spacing.small) {
                StatusChip.tag(StageOverviewCopy.destinations(viewModel.destinationCount))
                StatusChip.tag(StageOverviewCopy.manifestState(viewModel.manifestState, isReading: viewModel.isReadingManifest))
            }
            .padding(.top, Theme.Spacing.xSmall)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            if viewModel.stages.count > 1 {
                Picker(StageOverviewCopy.stagePicker, selection: $viewModel.stage) {
                    ForEach(viewModel.stages, id: \.self) { stage in
                        Text(verbatim: stage).tag(Optional(stage))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            Button(viewModel.showsManifestPanel ? StageOverviewCopy.hideCheck : StageOverviewCopy.showCheck) {
                viewModel.showsManifestPanel.toggle()
            }
            .fxButtonStyle(.outline)
            Button(StageOverviewCopy.readAgain) {
                viewModel.readManifest()
            }
            .fxButtonStyle(.secondary)
            .disabled(viewModel.isReadingManifest)
            Button(ProjectShareCopy.shareStage) {
                viewModel.shareStage()
            }
            .fxButtonStyle(.secondary)
            .disabled(viewModel.stage == nil)
            .help(ProjectShareCopy.shareStageHelp)
        }
        .fixedSize()
    }
}

/// "3 things to fix in production" (Show Check sits in the header), or that the stage matches
/// the manifest.
private struct OverviewFindingsBanner: View {
    let viewModel: StageOverviewViewModel
    let overview: StageOverviewModel

    var body: some View {
        if overview.usesManifest || !overview.findings.isEmpty {
            if overview.findings.isEmpty {
                Banner(.info, message: StageOverviewCopy.noFindings, systemImage: "checkmark.circle")
            } else {
                Banner(
                    .warning,
                    message: StageOverviewCopy.findingsBanner(
                        overview.findings.count,
                        stage: overview.stage,
                        usesManifest: overview.usesManifest
                    ),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }
}

/// The matrix: NAME, CYCLE and one column per place, a chip per cell (a click opens the place).
private struct OverviewMatrix: View {
    let viewModel: StageOverviewViewModel
    let overview: StageOverviewModel

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.medium, verticalSpacing: 0) {
                GridRow {
                    header(StageOverviewCopy.nameColumn, subtitle: nil)
                        .frame(minWidth: Theme.Layout.overviewNameMinWidth, alignment: .leading)
                    header(StageOverviewCopy.cycleColumn, subtitle: nil)
                        .frame(width: Theme.Layout.overviewCycleWidth, alignment: .leading)
                    ForEach(overview.columns) { column in
                        header(viewModel.title(of: column), subtitle: viewModel.subtitle(of: column))
                            .frame(minWidth: Theme.Layout.overviewCellMinWidth, alignment: .leading)
                    }
                }
                .padding(.vertical, Theme.Spacing.mediumMinus)
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(overview.rows) { row in
                    GridRow {
                        HStack(spacing: Theme.Spacing.small) {
                            Text(verbatim: row.name)
                                .fxTextStyle(.monoName)
                                .foregroundStyle(Theme.Colors.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            if row.linkCount > 1 {
                                StatusChip(title: String(row.linkCount), tone: .neutral, showsDot: false)
                                    .help(String(localized: "overview.linked.help", defaultValue: "Linked copies"))
                            }
                        }
                        StatusChip.tag(StageOverviewCopy.cycle(row.cycle))
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                            OverviewCell(cell: cell) {
                                viewModel.open(row: row, column: index)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.small)
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.small)
        }
        .fxCardBackground(.container)
    }

    private func header(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            SectionLabel(title)
            if let subtitle {
                Text(verbatim: subtitle)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// One cell's chip, or "—" for a place that does not use the name.
private struct OverviewCell: View {
    let cell: StageOverviewCellModel
    let open: () -> Void

    var body: some View {
        if cell == .notUsed {
            Text(verbatim: "—")
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityLabel(String(localized: "overview.cell.notUsed", defaultValue: "Not used here"))
        } else {
            Button(action: open) {
                StatusChip(title: StageOverviewCopy.cell(cell), tone: tone)
            }
            .buttonStyle(.plain)
            .help(String(localized: "overview.cell.open", defaultValue: "Show this place"))
        }
    }

    private var tone: StatusChip.Tone {
        switch cell {
        case .synced, .notUsed: .neutral
        case .willPush: .brand
        case .missing, .extra, .differs, .valueMissing, .held: .warning
        case .blocked, .willDelete: .danger
        }
    }
}

/// The `fxvault.yml` panel: parse issues, the stage's findings (with Add Destination where one is
/// missing), `.env.example` per target, and a generated `fxvault.yml` to copy.
private struct OverviewManifestPanel: View {
    let viewModel: StageOverviewViewModel
    let overview: StageOverviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.mediumMinus) {
                SectionLabel(StageOverviewCopy.manifestTitle)
                Spacer(minLength: 0)
                if !viewModel.exampleTargets.isEmpty {
                    Menu(StageOverviewCopy.copyExample) {
                        ForEach(viewModel.exampleTargets, id: \.name) { target in
                            Button(target.name) {
                                viewModel.copyEnvExample(target: target.name)
                            }
                        }
                    }
                    .menuStyle(.button)
                    .fxButtonStyle(.outline)
                    .fixedSize()
                }
                Button(StageOverviewCopy.copyDraft) {
                    viewModel.copyDraftManifest()
                }
                .fxButtonStyle(.outline)
                .help(StageOverviewCopy.copyDraftHelp)
            }
            ForEach(viewModel.parseIssues, id: \.self) { issue in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    StatusChip(title: StageOverviewCopy.issueLine(issue), tone: issue.severity == .error ? .danger : .warning)
                    Text(StageOverviewCopy.issue(issue))
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(overview.findings) { finding in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Text(StageOverviewCopy.finding(finding) { viewModel.columnTitle(id: $0) })
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if case .destinationNotAdded(_, let location) = finding, !Self.isGitHub(location) {
                        Button(StageOverviewCopy.addDestination) {
                            viewModel.addDestination(for: location)
                        }
                        .fxButtonStyle(.outline)
                        .fixedSize()
                    }
                }
            }
            if overview.findings.isEmpty, viewModel.parseIssues.isEmpty {
                Text(viewModel.manifest == nil
                    ? StageOverviewCopy.manifestState(viewModel.manifestState, isReading: viewModel.isReadingManifest)
                    : StageOverviewCopy.noFindings)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
        .padding(Theme.Spacing.largePlus)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCardBackground(.container)
    }

    private static func isGitHub(_ location: ManifestLocation) -> Bool {
        if case .githubEnvironment = location { return true }
        return false
    }
}
