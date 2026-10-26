import SwiftUI

/// The layout shared by the editor sheets of `ItemEditor/`, `Environment/` and the nested
/// `CreateRepo/` editors (§10 Sheets; board SyncReview, docs/DESIGN.md "Sheets"): a header
/// (eyebrow, 28 pt title, muted subtitle), labelled fields on the card ground, and a footer with
/// the secondary Cancel (Esc) and the primary pill (Return).
///
/// The primary button is the default action; destructive steps never sit behind it (they ask
/// through a confirmation whose default is Cancel).
struct ConfigEditorSheet<Content: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?
    let primaryTitle: String
    let isPrimaryEnabled: Bool
    let isWorking: Bool
    let width: CGFloat
    let onCancel: () -> Void
    let onPrimary: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        eyebrow: String? = nil,
        title: String,
        subtitle: String? = nil,
        primaryTitle: String,
        isPrimaryEnabled: Bool,
        isWorking: Bool,
        width: CGFloat = Theme.Layout.editorSheetWidth,
        onCancel: @escaping () -> Void,
        onPrimary: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.primaryTitle = primaryTitle
        self.isPrimaryEnabled = isPrimaryEnabled
        self.isWorking = isWorking
        self.width = width
        self.onCancel = onCancel
        self.onPrimary = onPrimary
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                    SheetHeader(label: eyebrow, title: title, subtitle: subtitle)
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.xxLarge)
            }
            HairlineDivider()
            ConfigSheetFooter(isWorking: isWorking) {
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: onCancel)
                    .fxButtonStyle(.secondary, size: .large)
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: onPrimary)
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isPrimaryEnabled)
            }
        }
        .frame(width: width)
        .fxSheetBackground()
    }
}

// MARK: - Sheet building blocks (board SyncReview)
//
// The header and the checkbox row are design components (``SheetHeader``, ``FXCheckboxRow``).

/// The footer of a sheet: mono meta (or a notice sentence) on the left, a spinner while working,
/// then the pills (secondary Cancel before the primary action, both `.large`). Meta that does not
/// fit on one line beside the pills moves to its own line above them.
struct ConfigSheetFooter<Actions: View>: View {
    /// Short meta in `.statusLine` (write limit, last check). Uppercased by the style.
    let meta: String?
    /// A full sentence (offline, a notice); shown instead of `meta` in caption type.
    let notice: String?
    let isWorking: Bool
    /// The padding around the row (``SheetFooterInset``).
    let inset: EdgeInsets
    @ViewBuilder let actions: () -> Actions

    init(
        meta: String? = nil,
        notice: String? = nil,
        isWorking: Bool = false,
        inset: EdgeInsets = SheetFooterInset.regular,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.meta = meta
        self.notice = notice
        self.isWorking = isWorking
        self.inset = inset
        self.actions = actions
    }

    var body: some View {
        SheetFooterLayout(
            spacing: Theme.Spacing.mediumMinus,
            rowSpacing: Theme.Spacing.small,
            allowsStacking: notice == nil && meta != nil
        ) {
            leading
            HStack(spacing: Theme.Spacing.mediumMinus) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                actions()
            }
            .fixedSize()
        }
        .padding(inset)
    }

    @ViewBuilder private var leading: some View {
        if let notice {
            Text(notice)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if let meta {
            Text(meta)
                .fxTextStyle(.statusLine)
                .foregroundStyle(Theme.Colors.subtleText)
                .lineLimit(2)
        } else {
            Color.clear
                .frame(width: 0, height: 0)
        }
    }
}

/// The padding around a sheet footer's row.
enum SheetFooterInset {
    /// The sheets' 32 pt sides and 20 pt above and below.
    static let regular = EdgeInsets(
        top: Theme.Spacing.largePlus,
        leading: Theme.Spacing.xxLarge,
        bottom: Theme.Spacing.largePlus,
        trailing: Theme.Spacing.xxLarge
    )
    /// The 1.0 dialogs (boards Sync-Progress, Sync-Delete): their 22 pt inset at the sides and
    /// below, 12 pt above (the content ends just before it).
    static let dialog = EdgeInsets(
        top: Theme.Spacing.medium,
        leading: Theme.Layout.dialogInset,
        bottom: Theme.Layout.dialogInset,
        trailing: Theme.Layout.dialogInset
    )
}

/// Lays out a sheet footer: the leading meta and the trailing pills on one row when the meta fits
/// on one line beside them; otherwise (with `allowsStacking`) the meta on its own line above the
/// pills, which stay trailing. Each view appears once, so keyboard shortcuts are not duplicated.
private struct SheetFooterLayout: Layout {
    let spacing: CGFloat
    let rowSpacing: CGFloat
    let allowsStacking: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard let (leading, trailing) = pair(subviews) else { return .zero }
        let trailingSize = trailing.sizeThatFits(.unspecified)
        let idealWidth = leading.sizeThatFits(.unspecified).width + spacing + trailingSize.width
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
        if isStacked(leading: leading, trailingWidth: trailingSize.width, width: width) {
            let leadingSize = leading.sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(width: width, height: leadingSize.height + rowSpacing + trailingSize.height)
        }
        let leadingSize = leading.sizeThatFits(ProposedViewSize(width: max(0, width - spacing - trailingSize.width), height: nil))
        return CGSize(width: width, height: max(leadingSize.height, trailingSize.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard let (leading, trailing) = pair(subviews) else { return }
        let trailingSize = trailing.sizeThatFits(.unspecified)
        if isStacked(leading: leading, trailingWidth: trailingSize.width, width: bounds.width) {
            let leadingProposal = ProposedViewSize(width: bounds.width, height: nil)
            let leadingHeight = leading.sizeThatFits(leadingProposal).height
            leading.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: leadingProposal)
            trailing.place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + leadingHeight + rowSpacing),
                anchor: .topTrailing,
                proposal: .unspecified
            )
            return
        }
        let leadingProposal = ProposedViewSize(width: max(0, bounds.width - spacing - trailingSize.width), height: nil)
        leading.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: leadingProposal)
        trailing.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }

    private func pair(_ subviews: Subviews) -> (LayoutSubview, LayoutSubview)? {
        guard subviews.count == 2, let leading = subviews.first, let trailing = subviews.last else { return nil }
        return (leading, trailing)
    }

    private func isStacked(leading: LayoutSubview, trailingWidth: CGFloat, width: CGFloat) -> Bool {
        allowsStacking && leading.sizeThatFits(.unspecified).width + spacing + trailingWidth > width
    }
}

/// A labelled field or block on the sheet ground: a ``SectionLabel`` above its content (field,
/// picker, notes). `labelAccessory` sits next to the label (a spinner, a Remove button).
struct ConfigSheetField<Content: View, LabelAccessory: View>: View {
    let label: String?
    @ViewBuilder let labelAccessory: () -> LabelAccessory
    @ViewBuilder let content: () -> Content

    init(
        _ label: String?,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder labelAccessory: @escaping () -> LabelAccessory
    ) {
        self.label = label
        self.content = content
        self.labelAccessory = labelAccessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
            if let label {
                HStack(spacing: Theme.Spacing.small) {
                    SectionLabel(label)
                    Spacer(minLength: 0)
                    labelAccessory()
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ConfigSheetField where LabelAccessory == EmptyView {
    init(_ label: String?, @ViewBuilder content: @escaping () -> Content) {
        self.init(label, content: content) { EmptyView() }
    }
}

/// A list in a hairline container card (16 pt corners): one padded row per element with a
/// hairline between rows (board SyncReview scope list).
struct ConfigSheetList<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    @ViewBuilder let row: (Data.Element) -> Row

    init(_ data: Data, @ViewBuilder row: @escaping (Data.Element) -> Row) {
        self.data = data
        self.row = row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(data.enumerated()), id: \.element.id) { index, element in
                if index > 0 {
                    HairlineDivider()
                }
                row(element)
                    .configSheetRowPadding()
            }
        }
        .fxCardBackground(.container)
    }
}

extension View {
    /// The padding of one row inside a `.container` card (``ConfigSheetList``).
    func configSheetRowPadding() -> some View {
        padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Notes

/// A one-line note under a field or in a form section: validation feedback, a warning or an
/// explanation. Never carries a value.
struct ConfigEditorNoteModel: Hashable {
    enum Tone: Hashable {
        case error
        case warning
        case info
        case success
    }

    let message: String
    let tone: Tone

    static func error(_ message: String) -> ConfigEditorNoteModel {
        ConfigEditorNoteModel(message: message, tone: .error)
    }

    static func warning(_ message: String) -> ConfigEditorNoteModel {
        ConfigEditorNoteModel(message: message, tone: .warning)
    }

    static func info(_ message: String) -> ConfigEditorNoteModel {
        ConfigEditorNoteModel(message: message, tone: .info)
    }

    static func success(_ message: String) -> ConfigEditorNoteModel {
        ConfigEditorNoteModel(message: message, tone: .success)
    }

    /// True when the note blocks the primary action.
    var isError: Bool {
        tone == .error
    }
}

/// Renders a ``ConfigEditorNoteModel`` with its icon and semantic color. The `.dialog` style
/// is the 11 pt note of a 1.0 dialog form (boards NewRepo, NewEnvironment): muted, or in the
/// tone's color for a warning or an error; only an error keeps its icon, so it does not rely
/// on color alone.
struct ConfigEditorNoteView: View {
    enum Style: Hashable {
        case standard
        case dialog
    }

    let note: ConfigEditorNoteModel
    var style: Style = .standard

    var body: some View {
        switch style {
        case .standard:
            Label {
                Text(note.message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: Self.systemImage(for: note.tone))
                    .foregroundStyle(Self.tint(for: note.tone))
            }
            .fxTextStyle(.caption)
            .foregroundStyle(Self.textColor(for: note.tone))
        case .dialog:
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xSmall) {
                if note.isError {
                    Image(systemName: Self.systemImage(for: note.tone))
                        .accessibilityHidden(true)
                }
                Text(verbatim: note.message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fxTextStyle(.formNote)
            .foregroundStyle(Self.dialogTextColor(for: note.tone))
        }
    }

    // MARK: Resolution (pure)

    static func systemImage(for tone: ConfigEditorNoteModel.Tone) -> String {
        switch tone {
        case .error: "exclamationmark.circle"
        case .warning: "exclamationmark.triangle"
        case .info: "info.circle"
        case .success: "checkmark.circle"
        }
    }

    static func tint(for tone: ConfigEditorNoteModel.Tone) -> Color {
        switch tone {
        case .error: Theme.Colors.danger
        case .warning: Theme.Colors.warning
        case .info: Theme.Colors.subtleText
        case .success: Theme.Colors.success
        }
    }

    /// Feedback reads in ink; explanations in muted text.
    static func textColor(for tone: ConfigEditorNoteModel.Tone) -> Color {
        tone == .info ? Theme.Colors.mutedText : Theme.Colors.ink
    }

    /// A dialog note has no tinted icon, so its text takes the tone's color; an explanation or
    /// a confirmation ("Not used in api-service yet") stays muted, as on the boards.
    static func dialogTextColor(for tone: ConfigEditorNoteModel.Tone) -> Color {
        switch tone {
        case .error, .warning: tint(for: tone)
        case .info, .success: Theme.Colors.mutedText
        }
    }
}

#Preview {
    ConfigEditorSheet(
        eyebrow: "Secrets and variables",
        title: "New Secret",
        subtitle: "In production of owner-a/fx-vault",
        primaryTitle: "Add",
        isPrimaryEnabled: true,
        isWorking: false,
        onCancel: {},
        onPrimary: {}
    ) {
        ConfigSheetField("Name") {
            FXTextField(label: nil, text: .constant("STRIPE_SECRET_KEY"), isMonospaced: true)
            ConfigEditorNoteView(note: .info("Names are uppercased."))
        }
        FXCheckboxRow(title: "Push on next Sync", isOn: .constant(true))
    }
}
