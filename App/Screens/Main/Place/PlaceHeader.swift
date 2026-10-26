import SwiftUI

/// The header of every place (1.0 D6c3; boards Main2-Repository, Place-Table, KV-Place,
/// Folder-View, Org-Visibility): the name, "kind · parent · counts", an optional status line,
/// then the place's own buttons and ⋯ More on the right, or under the name in a narrow column,
/// wrapping onto more lines when they don't fit there either.
struct PlaceHeader<Status: View, Accessories: View, MoreItems: View>: View {
    let title: String
    var titleStyle: SidebarTitleStyle = .mono
    let subline: String
    var titleHelp: String?
    /// ⋯ More; an edit of the notes has only its own buttons (board Place-Edit).
    var showsMore = true
    @ViewBuilder let status: () -> Status
    @ViewBuilder let accessories: () -> Accessories
    @ViewBuilder let moreItems: () -> MoreItems

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.large) {
                details
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                details
                // At `detailMinWidth` a folder's Copy To, Share Securely…, Notes | Table and ⋯
                // are wider than the column: they wrap instead of widening it.
                FlowLayout(spacing: Theme.Spacing.small) {
                    actionItems
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            Text(verbatim: title)
                .fxTextStyle(titleStyle == .mono ? .monoPlaceTitle : .placeTitle)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(titleHelp ?? title)
                .accessibilityAddTraits(.isHeader)
            Text(subline)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(subline)
                .accessibilityIdentifier(AccessibilityID.Place.subline)
            status()
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.small) {
            actionItems
        }
        .fixedSize()
    }

    @ViewBuilder
    private var actionItems: some View {
        accessories()
        if showsMore {
            Menu {
                moreItems()
            } label: {
                Label(PlaceCopy.more, systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fxIconButtonStyle(size: .compact)
            .help(PlaceCopy.more)
            .accessibilityIdentifier(AccessibilityID.Place.more)
        }
    }
}

extension PlaceHeader where Status == EmptyView {
    init(
        title: String,
        titleStyle: SidebarTitleStyle = .mono,
        subline: String,
        titleHelp: String? = nil,
        showsMore: Bool = true,
        @ViewBuilder accessories: @escaping () -> Accessories,
        @ViewBuilder moreItems: @escaping () -> MoreItems
    ) {
        self.init(
            title: title,
            titleStyle: titleStyle,
            subline: subline,
            titleHelp: titleHelp,
            showsMore: showsMore,
            status: { EmptyView() },
            accessories: accessories,
            moreItems: moreItems
        )
    }
}

extension PlaceHeader where Status == EmptyView, Accessories == EmptyView {
    init(
        title: String,
        titleStyle: SidebarTitleStyle = .mono,
        subline: String,
        titleHelp: String? = nil,
        @ViewBuilder moreItems: @escaping () -> MoreItems
    ) {
        self.init(
            title: title,
            titleStyle: titleStyle,
            subline: subline,
            titleHelp: titleHelp,
            status: { EmptyView() },
            accessories: { EmptyView() },
            moreItems: moreItems
        )
    }
}

extension View {
    /// A place's column (boards Main2): 28 pt sides, 20 pt top and bottom, the content at the
    /// top leading corner.
    func fxPlaceColumn() -> some View {
        padding(.horizontal, Theme.Spacing.xLargePlus)
            .padding(.vertical, Theme.Spacing.largePlus)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
