import SwiftUI

/// Step 3 (board Sync-Progress): the full-width bar, "Writing 5 of 8 · FX Vault writes 60 a
/// minute · Locking stops after the current write.", then the summary's places as cards whose
/// lines turn from a ring to a spinner to a check (a dash when they will not run). The
/// deletions come last, in a card of their own. Cancel After Current sits in the footer.
struct SyncRunView: View {
    let viewModel: SyncViewModel

    var body: some View {
        let progress = viewModel.progress
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
                VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
                    SyncProgressBar(fraction: progress.fraction)
                        .accessibilityElement()
                        .accessibilityLabel(Text(SyncCopy.progressTitle))
                        .accessibilityValue(Text(verbatim: accessibilityValue(progress)))
                    Text(verbatim: SyncCopy.progressLine(progress, phase: phaseText(progress)))
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(viewModel.progressCards) { card in
                    SyncProgressCard(card: card, state: viewModel.lineState)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Layout.compactSheetInset)
        }
    }

    /// Verifying and cloning say so; writing shows the count.
    private func phaseText(_ progress: SyncRunProgressModel) -> String? {
        switch progress.phase {
        case .starting, .writing:
            nil
        case .verifying(let scope):
            String(localized: "sync.progress.verifying", defaultValue: "Confirming the changes in \(scope)…")
        case .cloning:
            String(localized: "sync.progress.cloning", defaultValue: "Cloning the new repository…")
        }
    }

    /// VoiceOver: "API_TOKEN, 5 of 8".
    private func accessibilityValue(_ progress: SyncRunProgressModel) -> String {
        let count = String(localized: "sync.progress.count", defaultValue: "\(progress.completed) of \(progress.total)")
        return [progress.currentName, count].compactMap(\.self).joined(separator: ", ")
    }
}

/// The run's bar: ink over a hairline track, 4 pt, the sheet's width.
private struct SyncProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.Colors.hairline)
                Rectangle()
                    .fill(Theme.Colors.ink)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: Theme.Layout.syncProgressHeight)
        .clipShape(.rect(cornerRadius: Theme.Layout.syncProgressHeight / 2))
        .animation(Theme.Durations.interactionAnimation, value: fraction)
    }
}

/// One place of the run: the summary card's header (symbol, name, kind) and its lines with
/// their state in the symbol column.
private struct SyncProgressCard: View {
    let card: SyncProgressCardModel
    let state: (SyncProgressLineModel) -> SyncLineState

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SyncPlaceHeader(systemImage: card.systemImage, name: card.name, kind: card.kind)
            ForEach(card.lines) { line in
                SyncProgressLine(line: line, state: state(line))
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.mediumMinus)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxDialogCard()
    }
}

/// `✓ FEATURE_FLAGS  variable`: the state glyph, the mono name, the muted detail. A line that
/// will not run reads muted.
private struct SyncProgressLine: View {
    let line: SyncProgressLineModel
    let state: SyncLineState

    var body: some View {
        // The glyph's middle sits on the name's x-height, 4 pt above its baseline.
        let baselineLift = Theme.Spacing.xSmall
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            SyncLineStateGlyph(state: state)
                .frame(width: Theme.Layout.syncSymbolWidth, alignment: .leading)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + baselineLift }
            if let name = line.name {
                Text(verbatim: name)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(line.isBlocked ? Theme.Colors.subtleText : Theme.Colors.ink)
                    .lineLimit(1)
            }
            if let detail = line.detail {
                Text(verbatim: detail)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: SyncLineStateGlyph.title(state)))
    }
}

/// Done: a green check; writing: a small spinner; waiting: a ring; failed: a red cross; not run:
/// a dash (board Sync-Progress).
private struct SyncLineStateGlyph: View {
    let state: SyncLineState

    var body: some View {
        Group {
            switch state {
            case .done:
                Image(systemName: "checkmark")
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.success)
            case .writing:
                ProgressView()
                    .controlSize(.mini)
            case .waiting:
                Circle()
                    .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: Theme.Layout.syncWaitingDotStroke)
                    .frame(width: Theme.Layout.syncWaitingDotSize, height: Theme.Layout.syncWaitingDotSize)
            case .failed:
                Image(systemName: "xmark")
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.danger)
            case .skipped:
                Text(verbatim: "–")
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
        }
        .accessibilityHidden(true)
    }

    static func title(_ state: SyncLineState) -> String {
        switch state {
        case .waiting: String(localized: "sync.progress.state.waiting", defaultValue: "Waiting")
        case .writing: String(localized: "sync.progress.state.writing", defaultValue: "Writing")
        case .done: String(localized: "sync.progress.state.done", defaultValue: "Done")
        case .failed: String(localized: "sync.progress.state.failed", defaultValue: "Failed")
        case .skipped: String(localized: "sync.progress.state.skipped", defaultValue: "Not run")
        }
    }
}
