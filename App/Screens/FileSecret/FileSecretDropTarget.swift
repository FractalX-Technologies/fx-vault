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
                guard viewModel.acceptsOutsideEdits else { return false }
                Task {
                    viewModel.dropFiles(await FileDropURL.urls(from: providers))
                }
                return true
            }
            .overlay {
                if isTargeted, viewModel.acceptsOutsideEdits {
                    FileSecretDropOverlay(limit: viewModel.maxValueBytes, keepsFiles: viewModel.keepsDroppedFiles)
                }
            }
    }
}

/// "Drop to add as a file secret" over the place: a dashed ink outline 8 pt inside it. A folder
/// says that it keeps any other file too (v23).
private struct FileSecretDropOverlay: View {
    let limit: Int
    let keepsFiles: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: "doc.badge.plus")
                .font(Theme.Typography.emptyStateIcon)
                .foregroundStyle(Theme.Colors.ink)
                .accessibilityHidden(true)
            Text(keepsFiles ? FolderFileCopy.dropTitle : FileSecretCopy.dropTitle)
                .fxTextStyle(.leadEmphasized)
                .foregroundStyle(Theme.Colors.ink)
            Text(keepsFiles ? FolderFileCopy.dropDetail(secretLimit: limit) : FileSecretCopy.dropDetail(limit: limit))
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
    /// Every dropped file's URL, in the order dropped.
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url {
                urls.append(url)
            }
        }
        return urls
    }
}
