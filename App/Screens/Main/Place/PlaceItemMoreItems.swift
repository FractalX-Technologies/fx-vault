import SwiftUI
import VaultCore

/// The item actions every place's ⋯ More shares (1.0 D6c3; board Main2-Actions): New Secret and
/// New Variable (the kinds the place holds), Paste Multiple… and Import .env…, then the place's
/// own items, then Delete Selected… under one rule (``ConfigTableModel/canDeleteSelection``).
struct PlaceItemMoreItems<Model: ConfigTableModel, PlaceItems: View>: View {
    let viewModel: Model
    var kinds: [ConfigKind] = ConfigKind.allCases
    @ViewBuilder let placeItems: () -> PlaceItems

    var body: some View {
        Group {
            ForEach(kinds, id: \.self) { kind in
                Button(PlaceCopy.newItem(kind)) {
                    viewModel.add(kind)
                }
            }
            Divider()
            Button(PlaceCopy.pasteMultiple) {
                viewModel.pasteMultiple()
            }
            Button(PlaceCopy.importEnv) {
                viewModel.importEnvFile()
            }
        }
        .disabled(!viewModel.canEdit)
        placeItems()
        Divider()
        Button(PlaceCopy.deleteSelected, role: .destructive) {
            viewModel.deleteSelection()
        }
        .disabled(!viewModel.canDeleteSelection)
    }
}

extension PlaceItemMoreItems where PlaceItems == EmptyView {
    init(viewModel: Model, kinds: [ConfigKind] = ConfigKind.allCases) {
        self.init(viewModel: viewModel, kinds: kinds) { EmptyView() }
    }
}

/// "Refreshing…" on a place header's status line while Refresh reads the place again: a
/// repository's gh lists and a Key Vault's `az` read take seconds.
struct PlaceRefreshingLine: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ProgressView()
                .controlSize(.mini)
            Text(PlaceCopy.refreshing)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
        }
        .accessibilityElement(children: .combine)
    }
}
