import SwiftUI

/// The small uppercase SF Mono label above a section, a field or a table column
/// (`ENVIRONMENT`, `MASTER PASSWORD`, `ACCOUNTS`): 11 pt, +0.08em, subtle color.
///
/// ```swift
/// SectionLabel(String(localized: "main.detail.environment", defaultValue: "Environment"))
/// SectionLabel(step.title, color: Theme.Colors.brand)   // the current onboarding step
/// ```
///
/// Pass the title in sentence case; the label uppercases it, so translations keep their case
/// rules. A label that names a field should be the field's accessibility label as well.
struct SectionLabel: View {
    let title: String
    var color: Color = Theme.Colors.subtleText

    init(_ title: String, color: Color = Theme.Colors.subtleText) {
        self.title = title
        self.color = color
    }

    var body: some View {
        Text(title)
            .fxTextStyle(.sectionLabel)
            .foregroundStyle(color)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        SectionLabel("Environment")
        SectionLabel("02 Password", color: Theme.Colors.brand)
    }
    .padding(Theme.Spacing.xxLarge)
}
