import SwiftUI
import VaultCore

/// "Review changes to production" (board Place-Review): what Save turns into pending changes,
/// by Added, Changed and Removed. Return saves; Esc goes back to the editor with nothing saved.
struct NotesReviewSheet: View {
    let review: NotesReviewModel
    let session: NotesEditSession

    var body: some View {
        DialogSheet(title: review.title, subtitle: review.subtitle, footerNote: review.footer) {
            ForEach(review.sections) { section in
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Text(verbatim: section.title)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .accessibilityIdentifier(AccessibilityID.Place.notesReviewSection(section.id))
                    VStack(spacing: 0) {
                        ForEach(section.rows) { row in
                            if row.id != section.rows.first?.id {
                                Divider()
                                    .overlay(Theme.Colors.hairline)
                            }
                            NotesReviewRow(row: row)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                            .strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline)
                    )
                }
            }
        } actions: {
            Button(NotesEditCopy.cancel) {
                session.review = nil
            }
            .fxButtonStyle(.outline, size: .dialog)
            .keyboardShortcut(.cancelAction)
            Button(NotesEditCopy.save) {
                session.save()
            }
            .fxButtonStyle(.primary, size: .dialog)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(AccessibilityID.Place.notesReviewSave)
        }
        .frame(width: Theme.Layout.syncSheetWidth)
    }
}

/// `FEATURE_FLAGS  variable` and, at the trailing edge, `beta,search`, "value set" or
/// "info → debug".
private struct NotesReviewRow: View {
    let row: NotesReviewModel.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(verbatim: row.name)
                .fxTextStyle(.monoName)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(NotesEditCopy.kindWord(row.kind))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
            Spacer(minLength: Theme.Spacing.medium)
            if let detail = row.detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .frame(minHeight: Theme.Layout.dialogListRowHeight + Theme.Spacing.small)
        .accessibilityElement(children: .combine)
    }
}
