import SwiftUI

/// How a sidebar node's name is set: names from GitHub and Azure in SF Mono, the user's own
/// names (folders) in SF Pro (boards Main2-Home, Main2-Expanded).
enum SidebarTitleStyle {
    case mono
    case sans
}

/// One row of the sidebar tree (boards Main2-Home, Main2-Expanded): the disclosure chevron (or
/// its column, so names line up), a quiet symbol, the name and the trailing marks, indented one
/// step per level. The chevron toggles; the rest of the row is `action`, with `accessibilityID`.
struct SidebarTreeRow<Trailing: View>: View {
    let level: Int
    /// nil for a leaf.
    var isExpanded: Bool?
    let systemImage: String
    let title: String
    var titleStyle: SidebarTitleStyle = .mono
    let isSelected: Bool
    /// Not in the vault yet (a repository to import), or deleted.
    var isDimmed = false
    /// A deleted environment, until the next Sync.
    var isStruckThrough = false
    var accessibilityID: String?
    /// The chevron's VoiceOver label when it does more than show or hide the children.
    var toggleLabel: String?
    var toggleAccessibilityID: String?
    var onToggle: (() -> Void)?
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            chevron
            Button(action: action) {
                HStack(spacing: Theme.Spacing.smallMinus) {
                    Image(systemName: systemImage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(isDimmed ? Theme.Colors.subtleText : Theme.Colors.mutedText)
                        .frame(width: Theme.Layout.sidebarSymbolWidth)
                        .accessibilityHidden(true)
                    Text(verbatim: title)
                        .font(titleFont)
                        .strikethrough(isStruckThrough)
                        .foregroundStyle(isDimmed ? Theme.Colors.subtleText : Theme.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    trailing()
                }
                .frame(maxWidth: .infinity, minHeight: Theme.Layout.sidebarRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expansionValue)
            .modifier(OptionalAccessibilityID(id: accessibilityID))
        }
        .padding(.leading, CGFloat(level) * Theme.Layout.sidebarTreeIndent)
        .fxRowBackground(isSelected: isSelected, style: .sidebar)
    }

    private var titleFont: Font {
        switch titleStyle {
        case .mono: isSelected ? Theme.Typography.monoMetaEmphasized : Theme.Typography.monoMeta
        case .sans: isSelected ? Theme.Typography.captionEmphasized : Theme.Typography.caption
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if let isExpanded, let onToggle {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .rotationEffect(isExpanded ? .degrees(90) : .zero)
                    .frame(width: Theme.Layout.sidebarChevronWidth, height: Theme.Layout.sidebarRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(toggleLabel ?? (isExpanded ? SidebarCopy.collapse(title) : SidebarCopy.expand(title)))
            .modifier(OptionalAccessibilityID(id: toggleAccessibilityID))
        } else {
            Color.clear
                .frame(width: Theme.Layout.sidebarChevronWidth)
                .accessibilityHidden(true)
        }
    }

    private var expansionValue: String {
        switch isExpanded {
        case true?: SidebarCopy.expanded
        case false?: SidebarCopy.collapsed
        case nil: ""
        }
    }
}

extension SidebarTreeRow where Trailing == EmptyView {
    init(
        level: Int,
        isExpanded: Bool? = nil,
        systemImage: String,
        title: String,
        titleStyle: SidebarTitleStyle = .mono,
        isSelected: Bool,
        isDimmed: Bool = false,
        isStruckThrough: Bool = false,
        accessibilityID: String? = nil,
        toggleLabel: String? = nil,
        toggleAccessibilityID: String? = nil,
        onToggle: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            level: level,
            isExpanded: isExpanded,
            systemImage: systemImage,
            title: title,
            titleStyle: titleStyle,
            isSelected: isSelected,
            isDimmed: isDimmed,
            isStruckThrough: isStruckThrough,
            accessibilityID: accessibilityID,
            toggleLabel: toggleLabel,
            toggleAccessibilityID: toggleAccessibilityID,
            onToggle: onToggle,
            action: action
        ) {
            EmptyView()
        }
    }
}

/// Sets an accessibility identifier only when there is one.
private struct OptionalAccessibilityID: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

/// The line under a node that needs attention ("Needs admin:org · Approve", "Authorize SSO ·
/// Open"), aligned with the node's name.
struct SidebarSubline: View {
    let level: Int
    let text: String
    var actionTitle: String?
    /// The hover text when it says more than `text` (why an owner could not be listed).
    var help: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Text(text)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.subtleText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(help ?? text)
            if let actionTitle, let action {
                Text(verbatim: "·")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .accessibilityHidden(true)
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(Theme.Typography.labelEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
            }
            Spacer(minLength: 0)
        }
        .frame(height: Theme.Layout.sidebarSublineHeight)
        .padding(.leading, SidebarSubline.nameInset(level: level))
        .padding(.trailing, Theme.Spacing.small)
    }

    /// Where a node's name starts: its level, the row padding, the chevron and symbol columns.
    static func nameInset(level: Int) -> CGFloat {
        CGFloat(level) * Theme.Layout.sidebarTreeIndent + Theme.Spacing.small
            + Theme.Layout.sidebarChevronWidth + Theme.Spacing.smallMinus
            + Theme.Layout.sidebarSymbolWidth + Theme.Spacing.smallMinus
    }
}

/// The header of a sidebar section ("GitHub", "Azure", "Folders") with an optional trailing
/// control.
struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(title)
                .fxTextStyle(.sidebarSection)
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory()
        }
        .frame(height: Theme.Layout.sidebarSectionHeaderHeight, alignment: .bottom)
        .padding(.horizontal, Theme.Spacing.small)
    }
}

extension SidebarSectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title) {
            EmptyView()
        }
    }
}

/// The mono count at the trailing edge of a row (items, values missing), with what it counts as
/// its hover text and VoiceOver label.
struct SidebarCount: View {
    let value: Int
    let help: String

    var body: some View {
        Text(value, format: .number)
            .font(Theme.Typography.monoLabel)
            .monospacedDigit()
            .foregroundStyle(Theme.Colors.subtleText)
            .help(help)
            .accessibilityLabel(help)
    }
}

/// How many secrets of a repository, scope or Key Vault have no value in FX Vault (board
/// Main2-Repository: "api-service 3"); nothing at zero.
struct SidebarValueMissingCount: View {
    let count: Int

    var body: some View {
        if count > 0 {
            SidebarCount(value: count, help: SidebarCopy.valueMissingHelp(count))
        }
    }
}

/// The ink dot of a node with changes waiting for the next Sync.
struct SidebarPendingDot: View {
    var body: some View {
        // `StatusDot` hides itself from VoiceOver; this dot is the row's only pending cue.
        StatusDot(color: Theme.Colors.brand)
            .help(SidebarCopy.pending)
            .accessibilityElement()
            .accessibilityLabel(SidebarCopy.pending)
    }
}
