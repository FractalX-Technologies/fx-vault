import SwiftUI

/// The small terminal under a setup command (board GitHubSetup): the last lines it printed, in
/// mono, newest at the bottom.
struct CommandOutputView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(verbatim: lines[index])
                            .fxTextStyle(.monoMeta)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .textSelection(.enabled)
                .padding(Theme.Spacing.medium)
            }
            .frame(maxHeight: Theme.Layout.commandOutputMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .onAppear {
                proxy.scrollTo(lines.indices.last, anchor: .bottom)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Setup.output)
    }
}
