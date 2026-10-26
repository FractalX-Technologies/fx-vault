import SwiftUI

// The pieces every sheet and full-window form shares (docs/DESIGN.md, "Sheets"; boards
// SyncReview, Lock and Onboarding): the header, the quiet 12 pt callout row, the confirmation
// checkbox row, the inline error box, the brand text link and the content chrome of a system
// sheet. One implementation each; screens compose them.

// MARK: - Header

/// The top of a sheet or a full-window form: a ``SectionLabel`` eyebrow, the title and a muted
/// subtitle (board SyncReview: `REVIEW BEFORE SYNC` / 28 pt title / one muted line, 6 pt apart).
///
/// - `accessory` (Copy as Text, Refresh) sits at the trailing end of the eyebrow row, so the
///   title and subtitle use the full width; without an eyebrow (or when centered) it sits
///   beside them, top-aligned.
/// - The lock screen centers it with `.display` / `.lead` and 8 pt before the subtitle.
///
/// ```swift
/// SheetHeader(label: eyebrow, title: title, subtitle: subtitle)
/// SheetHeader(label: nil, title: headline, subtitle: text, titleStyle: .display,
///             subtitleStyle: .lead, subtitleSpacing: Theme.Spacing.small, alignment: .center)
/// ```
struct SheetHeader<Accessory: View>: View {
    let label: String?
    let title: String
    let subtitle: String?
    let titleStyle: Theme.TextStyle
    let subtitleStyle: Theme.TextStyle
    let subtitleSpacing: CGFloat
    let alignment: HorizontalAlignment
    @ViewBuilder let accessory: () -> Accessory

    init(
        label: String?,
        title: String,
        subtitle: String? = nil,
        titleStyle: Theme.TextStyle = .title,
        subtitleStyle: Theme.TextStyle = .body,
        subtitleSpacing: CGFloat = Theme.Spacing.smallMinus,
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.label = label
        self.title = title
        self.subtitle = subtitle
        self.titleStyle = titleStyle
        self.subtitleStyle = subtitleStyle
        self.subtitleSpacing = subtitleSpacing
        self.alignment = alignment
        self.accessory = accessory
    }

    var body: some View {
        if let label, alignment != .center {
            // The accessory shares the eyebrow row, so the title and subtitle get the full width.
            VStack(alignment: alignment, spacing: Theme.Spacing.smallMinus) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    SectionLabel(label)
                    Spacer(minLength: Theme.Spacing.medium)
                    accessory()
                        .fixedSize()
                }
                titleAndSubtitle
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
        } else {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                VStack(alignment: alignment, spacing: Theme.Spacing.smallMinus) {
                    if let label {
                        SectionLabel(label)
                    }
                    titleAndSubtitle
                }
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
                .layoutPriority(1)
                accessory()
                    .fixedSize()
            }
        }
    }

    private var titleAndSubtitle: some View {
        VStack(alignment: alignment, spacing: subtitleSpacing) {
            titleRow
            if let subtitle {
                Text(subtitle)
                    .fxTextStyle(subtitleStyle)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            Text(title)
                .fxTextStyle(titleStyle)
                .foregroundStyle(Theme.Colors.ink)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var textAlignment: TextAlignment {
        alignment == .center ? .center : .leading
    }
}

extension SheetHeader where Accessory == EmptyView {
    init(
        label: String?,
        title: String,
        subtitle: String? = nil,
        titleStyle: Theme.TextStyle = .title,
        subtitleStyle: Theme.TextStyle = .body,
        subtitleSpacing: CGFloat = Theme.Spacing.smallMinus,
        alignment: HorizontalAlignment = .leading
    ) {
        self.init(
            label: label,
            title: title,
            subtitle: subtitle,
            titleStyle: titleStyle,
            subtitleStyle: subtitleStyle,
            subtitleSpacing: subtitleSpacing,
            alignment: alignment
        ) { EmptyView() }
    }
}

// MARK: - Callout and checkbox rows

extension View {
    /// The quiet 12 pt row on the window `ground` with a hairline (board SyncReview confirmation
    /// row): stands out from a sheet's `card` background without a color.
    func fxCalloutBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        return padding(.vertical, Theme.Spacing.medium)
            .padding(.horizontal, Theme.Spacing.large)
            .background(Theme.Colors.ground, in: shape)
            .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline))
    }
}

/// A boxed note inside a sheet: a tinted symbol and a wrapped message on the callout row. For
/// warnings, failures and results that must stand out from the sheet's `card` background.
struct SheetCallout: View {
    let systemImage: String
    let tint: Color
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCalloutBackground()
        .accessibilityElement(children: .combine)
    }
}

/// A confirmation as a checkbox on the callout row (board SyncReview: "I understand that…").
/// `isBoxed: false` drops the row: the 1.0 dialogs draw the checkbox on the sheet (board
/// Sync-Delete).
struct FXCheckboxRow: View {
    let title: String
    @Binding var isOn: Bool
    var isBoxed = true

    var body: some View {
        let toggle = Toggle(isOn: $isOn) {
            Text(title)
                .fxTextStyle(.body)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        if isBoxed {
            toggle.fxCalloutBackground()
        } else {
            toggle
        }
    }
}

// MARK: - Errors

/// An error under a form or in a sheet: the danger symbol, the title and the message on the
/// danger ``Banner`` box, with room for several lines.
struct InlineErrorView: View {
    let error: ErrorPresentationModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
            Image(systemName: Banner.defaultSystemImage(for: .danger) ?? Self.fallbackSymbol)
                .foregroundStyle(Banner.symbolColor(for: .danger))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(error.title)
                    .fxTextStyle(.bodyEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                Text(error.message)
                    .fxTextStyle(.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Spacing.medium)
        .padding(.horizontal, Theme.Spacing.large)
        .background(Banner.background(for: .danger), in: Self.shape)
        .overlay(Self.shape.strokeBorder(Banner.border(for: .danger), lineWidth: Theme.Stroke.hairline))
        .accessibilityElement(children: .combine)
    }

    private static let fallbackSymbol = "exclamationmark.octagon"
    private static let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
}

// MARK: - Links

/// A text button in the brand color ("Use recovery key", "Edit"): no chrome, the pointing-hand
/// cursor, 40% when disabled.
struct FXLinkButtonStyle: ButtonStyle {
    var isEmphasized = false

    func makeBody(configuration: Configuration) -> some View {
        FXLinkButtonBody(isEmphasized: isEmphasized, configuration: configuration)
    }
}

private struct FXLinkButtonBody: View {
    let isEmphasized: Bool
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .fxTextStyle(isEmphasized ? .calloutEmphasized : .callout)
            .foregroundStyle(Theme.Colors.brand)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? Theme.Opacity.pressed : 1)
            .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
            .linkPointer()
    }
}

extension View {
    /// Applies ``FXLinkButtonStyle``.
    func fxLinkButtonStyle(isEmphasized: Bool = false) -> some View {
        buttonStyle(FXLinkButtonStyle(isEmphasized: isEmphasized))
    }

    /// The pointing-hand cursor over links.
    fileprivate func linkPointer() -> some View {
        pointerStyle(.link)
    }
}

// MARK: - System sheet content

extension View {
    /// The content of a system `.sheet` in the FractalX language: 32 pt padding on the `card`
    /// background, at `width` when given (board SyncReview).
    @ViewBuilder
    func fxSheetContent(width: CGFloat? = nil) -> some View {
        if let width {
            padding(Theme.Spacing.xxLarge)
                .frame(width: width)
                .fxSheetBackground()
        } else {
            padding(Theme.Spacing.xxLarge)
                .fxSheetBackground()
        }
    }
}

#Preview("Sheet chrome") {
    VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
        SheetHeader(
            label: "Review before sync",
            title: "5 changes to Example-Org/fx-vault",
            subtitle: "Names only. Values never leave this Mac in plain text."
        )
        SheetCallout(systemImage: "exclamationmark.triangle", tint: Theme.Colors.warning, text: "The file is not ignored by git.")
        FXCheckboxRow(title: "I understand that deleting LEGACY_TOKEN cannot be undone.", isOn: .constant(true))
        InlineErrorView(error: ErrorPresentationModel(title: "Could not unlock", message: "The password is wrong."))
        Button {} label: { Text(verbatim: "Use recovery key") }.fxLinkButtonStyle()
    }
    .fxSheetContent(width: Theme.Layout.syncSheetWidth)
}
