import SwiftUI

/// The pill tab selector of the mockup (Secrets 5 | Variables 8): a `surface2` track with the
/// selected segment as a `card` pill. Counts are SF Mono. Use it for 2 to 4 peer views of
/// the same content and for the kind / visibility choices of the editor sheets; use a native
/// `Picker` for settings. `.disabled` dims the whole control; `Segment.isEnabled` one segment.
/// `.small` is the 1.0 dialogs' control (boards NewRepo, Share-Pick): 22 pt segments with 6 pt
/// corners on an 8 pt track, 12 pt text.
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
    enum Size: Sendable {
        case regular
        case small
    }

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
    var size: Size = .regular
    @Namespace private var namespace
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(isSmall ? Theme.Layout.segmentTrackInsetSmall : Theme.Layout.segmentTrackInset)
        .background(Theme.Colors.surface2, in: trackShape)
        .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
        .animation(Theme.Durations.spring, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var isSmall: Bool {
        size == .small
    }

    private var trackShape: AnyShape {
        isSmall ? AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.compactRow, style: .continuous)) : AnyShape(Capsule.pill)
    }

    private var segmentShape: AnyShape {
        isSmall ? AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.token, style: .continuous)) : AnyShape(Capsule.pill)
    }

    private func titleFont(isSelected: Bool) -> Font {
        switch (isSmall, isSelected) {
        case (true, true): Theme.Typography.captionEmphasized
        case (true, false): Theme.Typography.caption
        case (false, true): Theme.Typography.calloutEmphasized
        case (false, false): Theme.Typography.callout
        }
    }

    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = segment.value == selection
        return Button {
            selection = segment.value
        } label: {
            HStack(spacing: Theme.Spacing.smallMinus) {
                Text(segment.title)
                    .font(titleFont(isSelected: isSelected))
                    .foregroundStyle(isSelected || isSmall ? Theme.Colors.ink : Theme.Colors.mutedText)
                if let count = segment.count {
                    Text(count, format: .number)
                        .font(Theme.Typography.monoName)
                        .foregroundStyle(isSelected ? Theme.Colors.subtleText : Theme.Colors.mutedText)
                }
            }
            .padding(.horizontal, isSmall ? Theme.Spacing.medium : Theme.Spacing.large)
            .frame(height: isSmall ? Theme.Layout.segmentHeightSmall : Theme.Layout.segmentHeight)
            .background {
                if isSelected {
                    segmentShape
                        .fill(Theme.Colors.card)
                        .overlay(segmentShape.stroke(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline).padding(Theme.Stroke.hairline / 2))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(segmentShape)
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
