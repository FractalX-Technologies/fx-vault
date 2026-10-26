import SwiftUI

/// One row of ``JumpResultsList``: what ``JumpRow`` draws, and what a click does.
struct JumpResultRowModel<ID: Hashable>: Identifiable {
    let id: ID
    let systemImage: String
    let name: String
    let titleStyle: SidebarTitleStyle
    let detail: String
    var hasPendingChanges = false
    let open: () -> Void

    init(place: JumpPlaceModel, id: ID, hasPendingChanges: Bool = false, open: @escaping () -> Void) {
        self.id = id
        systemImage = place.systemImage
        name = place.name
        titleStyle = place.titleStyle
        detail = place.detail
        self.hasPendingChanges = hasPendingChanges
        self.open = open
    }

    /// A secret or variable found by name, in mono.
    init(item: JumpItemModel, id: ID, open: @escaping () -> Void) {
        self.id = id
        systemImage = item.match.kind.symbolName
        name = item.name
        titleStyle = .mono
        detail = item.detail
        self.open = open
    }
}

/// "Places" (or "Recent") and "Secrets by name" with their rows, or "No matches": ⌘K's list and
/// the quick vault's (boards Main2-Search, QuickVault-Search). It scrolls to the selection.
struct JumpResultsList<ID: Hashable>: View {
    enum Height {
        /// As tall as the rows, up to the maximum, then it scrolls (⌘K).
        case upTo(CGFloat)
        /// One height whatever the rows, so the panel keeps its size (the quick vault).
        case fixed(CGFloat)
    }

    let placesTitle: String
    let places: [JumpResultRowModel<ID>]
    let items: [JumpResultRowModel<ID>]
    let selectedID: ID?
    let highlight: (String) -> Range<String.Index>?
    /// ⌘K marks the selected row with ↩; the quick vault's footer says it once.
    var showsReturnKey = true
    var inset: CGFloat = 0
    let height: Height

    var body: some View {
        ScrollViewReader { proxy in
            sized(
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sections
                    }
                    .padding(inset)
                }
            )
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    @ViewBuilder
    private var sections: some View {
        if !places.isEmpty || items.isEmpty {
            SidebarSectionHeader(placesTitle)
                .padding(.bottom, Theme.Spacing.xSmall)
        }
        if places.isEmpty && items.isEmpty {
            Text(JumpPaletteCopy.noMatches)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.subtleText)
                .padding(.horizontal, Theme.Spacing.small)
                .frame(height: Theme.Layout.jumpPaletteRowHeight)
        }
        rows(places)
        if !items.isEmpty {
            SidebarSectionHeader(JumpPaletteCopy.secretsByName)
                .padding(.top, places.isEmpty ? 0 : Theme.Spacing.small)
                .padding(.bottom, Theme.Spacing.xSmall)
            rows(items)
        }
    }

    private func rows(_ rows: [JumpResultRowModel<ID>]) -> some View {
        ForEach(rows) { row in
            JumpRow(
                systemImage: row.systemImage,
                name: row.name,
                titleStyle: row.titleStyle,
                detail: row.detail,
                highlight: highlight(row.name),
                isSelected: row.id == selectedID,
                showsReturnKey: showsReturnKey,
                hasPendingChanges: row.hasPendingChanges,
                open: row.open
            )
            .id(row.id)
        }
    }

    @ViewBuilder
    private func sized(_ list: some View) -> some View {
        switch height {
        case .upTo(let maximum):
            list
                .frame(maxHeight: maximum)
                .fixedSize(horizontal: false, vertical: true)
        case .fixed(let height):
            list.frame(height: height, alignment: .top)
        }
    }
}
