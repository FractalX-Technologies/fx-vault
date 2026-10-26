import SwiftUI
import UniformTypeIdentifiers
import VaultCore

extension View {
    /// Takes a file dragged onto the place (1.0 F1; board Place-FileDrop): the overlay while the
    /// drag is over it, then ``ConfigTableModel/dropFile(_:)``. Read-only places take nothing.
    func fileSecretDropTarget(_ viewModel: some ConfigTableModel) -> some View {
        modifier(FileSecretDropTarget(viewModel: viewModel))
    }
}

private struct FileSecretDropTarget<Model: ConfigTableModel>: ViewModifier {
    let viewModel: Model
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard viewModel.acceptsFileDrops else { return false }
                Task {
                    if let url = await FileDropURL.url(from: providers) {
                        viewModel.dropFile(url)
                    }
                }
                return true
            }
            .overlay {
                if isTargeted, viewModel.acceptsFileDrops {
                    FileSecretDropOverlay(limit: viewModel.maxValueBytes)
                }
            }
    }
}

/// "Drop to add as a file secret" over the place: a dashed ink outline 8 pt inside it.
private struct FileSecretDropOverlay: View {
    let limit: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: "doc.badge.plus")
                .font(Theme.Typography.emptyStateIcon)
                .foregroundStyle(Theme.Colors.ink)
                .accessibilityHidden(true)
            Text(FileSecretCopy.dropTitle)
                .fxTextStyle(.leadEmphasized)
                .foregroundStyle(Theme.Colors.ink)
            Text(FileSecretCopy.dropDetail(limit: limit))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(Theme.Colors.ink, style: StrokeStyle(lineWidth: Theme.Stroke.dropTarget, dash: Theme.Stroke.dashPattern)))
        .padding(Theme.Layout.fileDropInset)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// The file URL of a drop, loaded from its first provider that has one.
private enum FileDropURL {
    static func url(from providers: [NSItemProvider]) async -> URL? {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
