import AppKit
import SwiftUI

extension Theme {
    /// Fonts of the FractalX type scale (docs/DESIGN.md, "Type"): Geist Sans for the UI
    /// (headings 500, text 400) and Geist Mono for names, values, counts, timestamps and labels.
    /// Every font falls back to the system font through ``FontRegistry``.
    ///
    /// A `Font` cannot carry tracking or case. Headings and mono labels need both, so prefer the
    /// matching ``Theme/TextStyle`` with `.fxTextStyle(_:)`; use these fonts directly only where
    /// a `Font` is required (a `Label`, `Table` cells that set their own tracking, AppKit).
    enum Typography {
        // MARK: Geist Sans

        /// 44 pt, 500. The lock screen headline.
        static let display = FontRegistry.font(.sansMedium, size: Size.display, relativeTo: .largeTitle)
        /// 34 pt, 500. The environment heading, onboarding step titles.
        static let largeTitle = FontRegistry.font(.sansMedium, size: Size.largeTitle, relativeTo: .largeTitle)
        /// 28 pt, 500. Sheet titles.
        static let title = FontRegistry.font(.sansMedium, size: Size.title, relativeTo: .title)
        /// 20 pt, 500. Card and settings section titles.
        static let title2 = FontRegistry.font(.sansMedium, size: Size.title2, relativeTo: .title2)
        /// 15 pt, 500. The window title next to the mark, emphasized row titles.
        static let headline = FontRegistry.font(.sansMedium, size: Size.headline, relativeTo: .headline)
        /// 16 pt, 400. The paragraph under a display or large title.
        static let lead = FontRegistry.font(.sansRegular, size: Size.lead, relativeTo: .title3)
        /// 14 pt, 400. Default text; the window default font.
        static let body = FontRegistry.font(.sansRegular, size: Size.body, relativeTo: .body)
        /// 14 pt, 500. Primary button labels and emphasized body text.
        static let bodyEmphasized = FontRegistry.font(.sansMedium, size: Size.body, relativeTo: .body)
        /// 13 pt, 400. Sidebar and scope rows, regular buttons, links.
        static let callout = FontRegistry.font(.sansRegular, size: Size.callout, relativeTo: .callout)
        /// 13 pt, 500. The selected scope, regular primary buttons.
        static let calloutEmphasized = FontRegistry.font(.sansMedium, size: Size.callout, relativeTo: .callout)
        /// 12 pt, 400. Chips, captions under fields.
        static let caption = FontRegistry.font(.sansRegular, size: Size.caption, relativeTo: .caption)

        // MARK: Geist Mono

        /// 14 pt mono. Secret and variable names inside body text, recovery keys, commands.
        static let monospaced = FontRegistry.font(.monoRegular, size: Size.body, relativeTo: .body)
        /// 13 pt mono. Names in tables and lists.
        static let monoName = FontRegistry.font(.monoRegular, size: Size.callout, relativeTo: .callout)
        /// 12 pt mono. Timestamps, counts, repository paths, metadata.
        static let monoMeta = FontRegistry.font(.monoRegular, size: Size.caption, relativeTo: .caption)
        /// 11 pt mono. Uppercase section labels (with tracking: ``Theme/TextStyle/sectionLabel``).
        static let monoLabel = FontRegistry.font(.monoRegular, size: Size.label, relativeTo: .caption2)
        /// 20 pt mono, 500. Passphrase words (``Theme/TextStyle/passphraseWord``).
        static let passphraseWord = FontRegistry.font(.monoMedium, size: Size.title2, relativeTo: .title2)

        // MARK: AppKit

        /// Geist Mono at the body size for AppKit text views (the secret value editor and the
        /// `.env` paste editor), with the same system fallback as the SwiftUI fonts.
        static var nsMonospaced: NSFont {
            FontRegistry.nsFont(.monoRegular, size: Size.body)
        }

        // MARK: SF Symbols

        /// The symbol above an empty state.
        static let emptyStateIcon = Font.system(size: Theme.Layout.emptyStateIconSize, weight: .light)

        /// Point sizes of the scale.
        enum Size {
            static let display: CGFloat = 44
            static let largeTitle: CGFloat = 34
            static let title: CGFloat = 28
            static let title2: CGFloat = 20
            static let lead: CGFloat = 16
            static let headline: CGFloat = 15
            static let body: CGFloat = 14
            static let callout: CGFloat = 13
            static let caption: CGFloat = 12
            static let label: CGFloat = 11
        }

        /// Letter spacing in em (multiplied by the point size).
        enum Tracking {
            /// Display and large titles.
            static let display: CGFloat = -0.04
            /// Titles.
            static let title: CGFloat = -0.03
            /// Card titles.
            static let title2: CGFloat = -0.02
            /// The window title and other 15 pt headings.
            static let headline: CGFloat = -0.013
            /// Uppercase mono section labels.
            static let label: CGFloat = 0.08
            /// Mono status lines and the step counter.
            static let counter: CGFloat = 0.06
            /// Masked values (bullets breathe a little).
            static let maskedValue: CGFloat = 0.08
        }

        /// Extra space between lines, in points, for multi-line paragraphs.
        enum LineSpacing {
            /// The `lead` paragraph (16/25).
            static let lead: CGFloat = 6
            /// Body paragraphs (14/20).
            static let body: CGFloat = 3
            /// Display and large titles (44/46, 34/38): tight.
            static let display: CGFloat = 0
        }
    }

    /// A complete text style: font, tracking, line spacing and case. Apply it with
    /// `.fxTextStyle(.title)`. Color stays the caller's (`.foregroundStyle`); ``SectionLabel``
    /// wraps `.sectionLabel` with its subtle color.
    struct TextStyle: Sendable {
        let font: Font
        /// Letter spacing in em; the modifier multiplies it by `size`.
        let trackingEm: CGFloat
        let size: CGFloat
        let lineSpacing: CGFloat
        let isUppercase: Bool

        init(font: Font, size: CGFloat, trackingEm: CGFloat = 0, lineSpacing: CGFloat = 0, isUppercase: Bool = false) {
            self.font = font
            self.size = size
            self.trackingEm = trackingEm
            self.lineSpacing = lineSpacing
            self.isUppercase = isUppercase
        }

        /// Tracking in points.
        var tracking: CGFloat { size * trackingEm }
    }
}

extension Theme.TextStyle {
    private typealias Typography = Theme.Typography

    /// 44 pt, 500, -0.04em. The lock headline.
    static let display = Self(font: Typography.display, size: Typography.Size.display, trackingEm: Typography.Tracking.display)
    /// 34 pt, 500, -0.03em. Environment heading, onboarding step titles.
    static let largeTitle = Self(font: Typography.largeTitle, size: Typography.Size.largeTitle, trackingEm: Typography.Tracking.title)
    /// 28 pt, 500, -0.03em. Sheet titles.
    static let title = Self(font: Typography.title, size: Typography.Size.title, trackingEm: Typography.Tracking.title)
    /// 20 pt, 500, -0.02em. Card and settings section titles.
    static let title2 = Self(font: Typography.title2, size: Typography.Size.title2, trackingEm: Typography.Tracking.title2)
    /// 15 pt, 500. The window title, emphasized row titles.
    static let headline = Self(font: Typography.headline, size: Typography.Size.headline, trackingEm: Typography.Tracking.headline)
    /// 16 pt, 400, 25 pt lines. The paragraph under a display or large title.
    static let lead = Self(font: Typography.lead, size: Typography.Size.lead, lineSpacing: Typography.LineSpacing.lead)
    /// 14 pt, 400, 20 pt lines.
    static let body = Self(font: Typography.body, size: Typography.Size.body, lineSpacing: Typography.LineSpacing.body)
    /// 14 pt, 500.
    static let bodyEmphasized = Self(font: Typography.bodyEmphasized, size: Typography.Size.body)
    /// 13 pt, 400.
    static let callout = Self(font: Typography.callout, size: Typography.Size.callout)
    /// 13 pt, 500.
    static let calloutEmphasized = Self(font: Typography.calloutEmphasized, size: Typography.Size.callout)
    /// 12 pt, 400.
    static let caption = Self(font: Typography.caption, size: Typography.Size.caption)

    /// 14 pt mono. Names inside body text, recovery keys, commands.
    static let mono = Self(font: Typography.monospaced, size: Typography.Size.body)
    /// 13 pt mono. Names in tables and lists (`STRIPE_SECRET_KEY`).
    static let monoName = Self(font: Typography.monoName, size: Typography.Size.callout)
    /// 13 pt mono, +0.08em. Masked values (`••••••••••••`).
    static let monoValue = Self(font: Typography.monoName, size: Typography.Size.callout, trackingEm: Typography.Tracking.maskedValue)
    /// 12 pt mono. Timestamps, counts, repository paths.
    static let monoMeta = Self(font: Typography.monoMeta, size: Typography.Size.caption)
    /// 12 pt mono, +0.06em. The onboarding step counter (`02 / 05`).
    static let monoCounter = Self(font: Typography.monoMeta, size: Typography.Size.caption, trackingEm: Typography.Tracking.counter)
    /// 11 pt mono, uppercase, +0.08em. Section labels (`ENVIRONMENT`, `MASTER PASSWORD`).
    static let sectionLabel = Self(font: Typography.monoLabel, size: Typography.Size.label, trackingEm: Typography.Tracking.label, isUppercase: true)
    /// 11 pt mono, uppercase, +0.06em. Status lines (`PASSWORD REQUIRED AFTER RESTART`).
    static let statusLine = Self(font: Typography.monoLabel, size: Typography.Size.label, trackingEm: Typography.Tracking.counter, isUppercase: true)
    /// 20 pt mono 500. A word of a generated passphrase (share export, onboarding).
    static let passphraseWord = Self(font: Typography.passphraseWord, size: Typography.Size.title2)
}

private struct FXTextStyleModifier: ViewModifier {
    let style: Theme.TextStyle

    func body(content: Content) -> some View {
        content
            .font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
            .textCase(style.isUppercase ? .uppercase : nil)
    }
}

extension View {
    /// Applies a complete ``Theme/TextStyle`` (font, tracking, line spacing, case).
    func fxTextStyle(_ style: Theme.TextStyle) -> some View {
        modifier(FXTextStyleModifier(style: style))
    }
}
