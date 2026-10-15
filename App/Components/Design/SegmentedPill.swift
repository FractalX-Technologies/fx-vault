import SwiftUI

/// The pill tab selector of the mockup (Secrets 5 | Variables 8): a `surface2` track with the
/// selected segment as a `card` pill. Counts are Geist Mono. Use it for 2 to 4 peer views of
/// the same content and for the kind / visibility choices of the editor sheets; use a native
/// `Picker` for settings. `.disabled` dims the whole control; `Segment.isEnabled` one segment.
///
/// ```swift
/// SegmentedPill(
///     selection: $viewModel.kind,
///     segments: [
///         .init(value: .secret, title: String(localized: "main.kind.secrets", defaultValue: "Secrets"), count: secretCount),
///         .init(value: .variable, title: String(localized: "main.kind.variables", defaultValue: "Variables"), count: variableCount),
///     ],
///     accessibilityLabel: String(localized: "main.kind.accessibility", defaultValue: "Kind")
/// )
/// ```
struct SegmentedPill<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let title: String
        var count: Int?
        /// `false` dims the segment to 40% and makes it unselectable (an option that does not
        /// apply, like a move to the kind the item already has).
        var isEnabled = true

        var id: Value { value }

        init(value: Value, title: String, count: Int? = nil, isEnabled: Bool = true) {
            self.value = value
            self.title = title
            self.count = count
            self.isEnabled = isEnabled
        }
    }

    @Binding var selection: Value
    let segments: [Segment]
    let accessibilityLabel: String
    @Namespace private var namespace
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(Theme.Layout.segmentTrackInset)
        .background(Theme.Colors.surface2, in: .pill)
        .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
        .animation(Theme.Durations.spring, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = segment.value == selection
        return Button {
            selection = segment.value
        } label: {
            HStack(spacing: Theme.Spacing.smallMinus) {
                Text(segment.title)
                    .font(isSelected ? Theme.Typography.calloutEmphasized : Theme.Typography.callout)
                    .foregroundStyle(isSelected ? Theme.Colors.ink : Theme.Colors.mutedText)
                if let count = segment.count {
                    Text(count, format: .number)
                        .font(Theme.Typography.monoName)
                        .foregroundStyle(isSelected ? Theme.Colors.subtleText : Theme.Colors.mutedText)
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .frame(height: Theme.Layout.segmentHeight)
            .background {
                if isSelected {
                    Capsule.pill
                        .fill(Theme.Colors.card)
                        .overlay(Capsule.pill.strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(.pill)
        }
        .buttonStyle(.plain)
        .disabled(!segment.isEnabled)
        .opacity(segment.isEnabled || !isEnabled ? 1 : Theme.Opacity.disabled)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

#Preview {
    SegmentedPill(
        selection: .constant(0),
        segments: [.init(value: 0, title: "Secrets", count: 5), .init(value: 1, title: "Variables", count: 8)],
        accessibilityLabel: "Kind"
    )
    .padding(Theme.Spacing.xxLarge)
    .background(Theme.Colors.ground)
}
