import AppKit
import SwiftUI

extension Theme {
    /// Fonts of the 1.0 type scale (docs/DESIGN.md, "Type"): the system font (SF Pro) for the
    /// UI, headings semibold, and SF Mono for names, values, counts, timestamps and labels.
    ///
    /// A `Font` cannot carry tracking or case. Mono labels need both, so prefer the matching
    /// ``Theme/TextStyle`` with `.fxTextStyle(_:)`; use these fonts directly only where a `Font`
    /// is required (a `Label`, `Table` cells that set their own tracking, AppKit).
    enum Typography {
        // MARK: SF Pro

        /// 32 pt, semibold. The lock screen headline.
        static let display = Font.system(size: Size.display, weight: .semibold)
        /// 24 pt, semibold. The environment heading, onboarding step titles.
        static let largeTitle = Font.system(size: Size.largeTitle, weight: .semibold)
        /// 22 pt, semibold. Sheet titles.
        static let title = Font.system(size: Size.title, weight: .semibold)
        /// 17 pt, semibold. Card and settings section titles.
        static let title2 = Font.system(size: Size.title2, weight: .semibold)
        /// 13 pt, semibold. Emphasized row titles.
        static let headline = Font.system(size: Size.headline, weight: .semibold)
        /// 15 pt. The paragraph under a display or large title.
        static let lead = Font.system(size: Size.lead)
        /// 15 pt, semibold. Compact sheet titles ("Review Sync").
        static let leadEmphasized = Font.system(size: Size.lead, weight: .semibold)
        /// 13 pt. Default text; the window default font.
        static let body = Font.system(size: Size.body)
        /// 13 pt, medium. Primary button labels and emphasized body text.
        static let bodyEmphasized = Font.system(size: Size.body, weight: .medium)
        /// 13 pt. Sidebar rows, regular buttons, links.
        static let callout = Font.system(size: Size.callout)
        /// 13 pt, semibold. The selected environment, regular primary buttons.
        static let calloutEmphasized = Font.system(size: Size.callout, weight: .semibold)
        /// 12 pt. Chips, captions under fields, secondary text.
        static let caption = Font.system(size: Size.caption)
        /// 12 pt, medium. The selected folder in the sidebar tree.
        static let captionEmphasized = Font.system(size: Size.caption, weight: .medium)
        /// 12 pt, semibold. A place's name heading a Sync summary card.
        static let placeName = Font.system(size: Size.caption, weight: .semibold)
        /// 11 pt. Sublines under sidebar nodes.
        static let label = Font.system(size: Size.label)
        /// 11 pt, medium. Sidebar section headers and the action of a subline.
        static let labelEmphasized = Font.system(size: Size.label, weight: .medium)

        // MARK: SF Mono

        /// 13 pt mono. Secret and variable names inside body text, recovery keys, commands.
        static let monospaced = Font.system(size: Size.body, design: .monospaced)
        /// 13 pt mono. Names in tables and lists.
        static let monoName = Font.system(size: Size.callout, design: .monospaced)
        /// 12 pt mono. Timestamps, counts, repository paths, metadata; names in the sidebar tree.
        static let monoMeta = Font.system(size: Size.caption, design: .monospaced)
        /// 12 pt mono, medium. The selected name in the sidebar tree.
        static let monoMetaEmphasized = Font.system(size: Size.caption, weight: .medium, design: .monospaced)
        /// 11 pt mono. Uppercase section labels (with tracking: ``Theme/TextStyle/sectionLabel``).
        static let monoLabel = Font.system(size: Size.label, design: .monospaced)
        /// 17 pt mono, medium. Passphrase words (``Theme/TextStyle/passphraseWord``).
        static let passphraseWord = Font.system(size: Size.title2, weight: .medium, design: .monospaced)

        // MARK: AppKit

        /// SF Mono at the body size for AppKit text views (the secret value editor and the `.env`
        /// paste editor).
        static var nsMonospaced: NSFont {
            NSFont.monospacedSystemFont(ofSize: Size.body, weight: .regular)
        }

        // MARK: SF Symbols

        /// The symbol above an empty state.
        static let emptyStateIcon = Font.system(size: Theme.Layout.emptyStateIconSize, weight: .light)

        /// Point sizes of the scale.
        enum Size {
            static let display: CGFloat = 32
            static let largeTitle: CGFloat = 24
            static let title: CGFloat = 22
            static let title2: CGFloat = 17
            static let lead: CGFloat = 15
            static let headline: CGFloat = 13
            static let body: CGFloat = 13
            static let callout: CGFloat = 13
            static let caption: CGFloat = 12
            static let label: CGFloat = 11
        }

        /// Letter spacing in em (multiplied by the point size).
        enum Tracking {
            /// Uppercase mono section labels.
            static let label: CGFloat = 0.08
            /// Mono status lines and the step counter.
            static let counter: CGFloat = 0.06
            /// Masked values (bullets breathe a little).
            static let maskedValue: CGFloat = 0.08
        }

        /// Extra space between lines, in points, for multi-line paragraphs.
        enum LineSpacing {
            /// The `lead` paragraph (15/22).
            static let lead: CGFloat = 5
            /// Body paragraphs (13/18).
            static let body: CGFloat = 3
            /// Display and large titles: tight.
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

    /// 32 pt, semibold. The lock headline.
    static let display = Self(font: Typography.display, size: Typography.Size.display)
    /// 24 pt, semibold. Environment heading, onboarding step titles.
    static let largeTitle = Self(font: Typography.largeTitle, size: Typography.Size.largeTitle)
    /// 22 pt, semibold. Sheet titles.
    static let title = Self(font: Typography.title, size: Typography.Size.title)
    /// 17 pt, semibold. Card and settings section titles.
    static let title2 = Self(font: Typography.title2, size: Typography.Size.title2)
    /// 13 pt, semibold. Emphasized row titles.
    static let headline = Self(font: Typography.headline, size: Typography.Size.headline)
    /// 15 pt, 22 pt lines. The paragraph under a display or large title.
    static let lead = Self(font: Typography.lead, size: Typography.Size.lead, lineSpacing: Typography.LineSpacing.lead)
    /// 15 pt, semibold. Compact sheet titles ("Review Sync").
    static let leadEmphasized = Self(font: Typography.leadEmphasized, size: Typography.Size.lead)
    /// 13 pt, 18 pt lines.
    static let body = Self(font: Typography.body, size: Typography.Size.body, lineSpacing: Typography.LineSpacing.body)
    /// 13 pt, medium.
    static let bodyEmphasized = Self(font: Typography.bodyEmphasized, size: Typography.Size.body)
    /// 13 pt.
    static let callout = Self(font: Typography.callout, size: Typography.Size.callout)
    /// 13 pt, semibold.
    static let calloutEmphasized = Self(font: Typography.calloutEmphasized, size: Typography.Size.callout)
    /// 12 pt.
    static let caption = Self(font: Typography.caption, size: Typography.Size.caption)
    /// 12 pt, semibold. A place's name heading a Sync summary card (`api-service › production`).
    static let placeName = Self(font: Typography.placeName, size: Typography.Size.caption)

    /// 13 pt mono. Names inside body text, recovery keys, commands.
    static let mono = Self(font: Typography.monospaced, size: Typography.Size.body)
    /// 13 pt mono. Names in tables and lists (`STRIPE_SECRET_KEY`).
    static let monoName = Self(font: Typography.monoName, size: Typography.Size.callout)
    /// 13 pt mono, +0.08em. Masked values (`••••••••••••`).
    static let monoValue = Self(font: Typography.monoName, size: Typography.Size.callout, trackingEm: Typography.Tracking.maskedValue)
    /// 12 pt mono. Timestamps, counts, repository paths.
    static let monoMeta = Self(font: Typography.monoMeta, size: Typography.Size.caption)
    /// 12 pt mono, +0.06em. The onboarding step counter (`02 / 05`).
    static let monoCounter = Self(font: Typography.monoMeta, size: Typography.Size.caption, trackingEm: Typography.Tracking.counter)
    /// 11 pt, medium, sentence case. The sidebar's sections ("GitHub", "Azure", "Folders").
    static let sidebarSection = Self(font: Typography.labelEmphasized, size: Typography.Size.label)
    /// 11 pt mono, uppercase, +0.08em. Section labels (`ENVIRONMENT`, `MASTER PASSWORD`).
    static let sectionLabel = Self(font: Typography.monoLabel, size: Typography.Size.label, trackingEm: Typography.Tracking.label, isUppercase: true)
    /// 11 pt mono, uppercase, +0.06em. Status lines (`PASSWORD REQUIRED AFTER RESTART`).
    static let statusLine = Self(font: Typography.monoLabel, size: Typography.Size.label, trackingEm: Typography.Tracking.counter, isUppercase: true)
    /// 17 pt mono, medium. A word of a generated passphrase (share export, onboarding).
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
