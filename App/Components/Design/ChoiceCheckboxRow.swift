import SwiftUI

/// A chooser's row (Connect's sources and vaults, Choose Repositories): a checkbox with a name,
/// a caption and an optional trailing view, on the callout background. The label fills the row,
/// so a click anywhere on it toggles; a click on its empty part used to do nothing.
struct ChoiceCheckboxRow<Trailing: View>: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let isDisabled: Bool
    let accessibilityID: String
    let toggle: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in toggle() })) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: title)
                        .fxTextStyle(.bodyEmphasized)
                        .foregroundStyle(Theme.Colors.ink)
                    Text(verbatim: detail)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.subtleText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .toggleStyle(.checkbox)
            .disabled(isDisabled)
            .accessibilityIdentifier(accessibilityID)
            // Outside the toggle: a disabled row's chip says why, so it must not dim with it.
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCalloutBackground()
    }
}

extension ChoiceCheckboxRow where Trailing == EmptyView {
    init(
        title: String,
        detail: String,
        isSelected: Bool,
        isDisabled: Bool,
        accessibilityID: String,
        toggle: @escaping () -> Void
    ) {
        self.init(
            title: title,
            detail: detail,
            isSelected: isSelected,
            isDisabled: isDisabled,
            accessibilityID: accessibilityID,
            toggle: toggle
        ) {
            EmptyView()
        }
    }
}
