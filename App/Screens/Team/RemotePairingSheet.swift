import SwiftUI

/// Add Teammate › Not Nearby… (v0.9.0, P4): Create Invitation and send it, or, for an opened
/// `.fxvcard`, the invitation (Create Reply) or the reply, then the six words to compare on a
/// call and The Words Match. The presenter calls ``RemotePairingViewModel/close()`` when the
/// sheet goes away.
struct RemotePairingSheet: View {
    let viewModel: RemotePairingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            SheetHeader(label: RemotePairingCopy.eyebrow, title: title, subtitle: subtitle) {
                StatusChip.tag(RemotePairingCopy.experimental)
                    .help(RemotePairingCopy.experimentalHelp)
            }
            content
            if let notice = viewModel.notice {
                Text(notice)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: Theme.Layout.addTeammateSheetWidth)
        .background {
            if let delivery = viewModel.delivery as? SystemPairingCardDelivery {
                ShareDeliveryAnchor(delivery: delivery.picker)
            }
        }
    }

    private var title: String {
        switch viewModel.step {
        case .start, .failed, .paired: RemotePairingCopy.title
        case .invitationReady: RemotePairingCopy.invitationReadyTitle
        case .invitation(let person): RemotePairingCopy.invitationTitle(person.name)
        case .replyReady: RemotePairingCopy.replyReadyTitle
        case .reply(let person, _): RemotePairingCopy.replyTitle(person.name)
        }
    }

    private var subtitle: String? {
        switch viewModel.step {
        case .start: RemotePairingCopy.startSubtitle
        case .invitationReady: RemotePairingCopy.invitationReadyMessage
        case .invitation(let person): RemotePairingCopy.invitationMessage(person.name)
        case .replyReady(let person, _): RemotePairingCopy.replyReadyMessage(person.name)
        case .reply(let person, _): RemotePairingCopy.replyMessage(person.name)
        case .paired, .failed: nil
        }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.step {
        case .start:
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(Array(RemotePairingCopy.steps.enumerated()), id: \.offset) { index, text in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Text(StepCounter.padded(index + 1))
                            .fxTextStyle(.monoMeta)
                            .foregroundStyle(Theme.Colors.subtleText)
                            .accessibilityHidden(true)
                        Text(text)
                            .fxTextStyle(.body)
                            .foregroundStyle(Theme.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxCalloutBackground()
            note(RemotePairingCopy.publicKeysNote)
        case .invitationReady:
            deliveryButtons
        case .invitation(let person):
            personCard(person)
        case .replyReady(let person, let code):
            personCard(person)
            deliveryButtons
            PairingCodeView(words: code)
        case .reply(let person, let code):
            personCard(person)
            PairingCodeView(words: code)
        case .paired(let name, let wasUpdate):
            Banner(.info, message: wasUpdate ? RemotePairingCopy.updated(name) : RemotePairingCopy.paired(name))
        case .failed(let message):
            Banner(.warning, message: message)
        }
    }

    private func personCard(_ person: RemotePairingPersonModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            Text(verbatim: person.name)
                .fxTextStyle(.bodyEmphasized)
                .foregroundStyle(Theme.Colors.ink)
            if !person.detail.isEmpty {
                Text(verbatim: person.detail)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if person.isExistingTeammate {
                Text(RemotePairingCopy.alreadyTeammate(person.name))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.xxSmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCalloutBackground()
    }

    private var deliveryButtons: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button {
                viewModel.share()
            } label: {
                Label(RemotePairingCopy.share, systemImage: "square.and.arrow.up")
            }
            .fxButtonStyle(.primary)
            Button(RemotePairingCopy.save) {
                Task { await viewModel.save() }
            }
            .fxButtonStyle(.outline)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: Theme.Spacing.small) {
            Spacer()
            switch viewModel.step {
            case .start:
                cancelButton
                Button(RemotePairingCopy.createInvitation) {
                    viewModel.createInvitation()
                }
                .fxButtonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            case .invitation:
                cancelButton
                Button(RemotePairingCopy.createReply) {
                    viewModel.createReply()
                }
                .fxButtonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            case .replyReady, .reply:
                cancelButton
                // As the nearby code (`SASDecision`): the same secondary pill as Cancel and never
                // the default button, so confirming is a deliberate click and neither answer looks
                // preferred.
                Button(RemotePairingCopy.wordsMatch) {
                    viewModel.confirm()
                }
                .fxButtonStyle(SASDecision.match.buttonVariant)
            case .invitationReady, .paired, .failed:
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    dismiss()
                }
                .fxButtonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var cancelButton: some View {
        Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
            dismiss()
        }
        .fxButtonStyle(.secondary)
        .keyboardShortcut(.cancelAction)
    }
}

/// The six words of a remote pairing (v0.9.0), large and numbered so they can be read out on a
/// call. Not secret: they are derived from public cards.
struct PairingCodeView: View {
    let words: [String]

    /// Two columns, like ``PassphraseView``.
    private let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.large, alignment: .leading),
        GridItem(.flexible(), spacing: Theme.Spacing.large, alignment: .leading),
    ]

    var body: some View {
        Card(spacing: Theme.Spacing.large) {
            SectionLabel(RemotePairingCopy.codeTitle)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.medium) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Text(StepCounter.padded(index + 1))
                            .fxTextStyle(.monoMeta)
                            .foregroundStyle(Theme.Colors.subtleText)
                            .accessibilityHidden(true)
                        Text(verbatim: word)
                            .fxTextStyle(.passphraseWord)
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }
            Text(RemotePairingCopy.codeWarning)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}

/// An opened `.fxvcard` (v0.9.0): an invitation or a reply.
struct RemotePairingContext: Hashable {
    let fileURL: URL
}

/// The main window's entry view for an opened `.fxvcard` (UI feature contract): reads the
/// file, then shows ``RemotePairingSheet``. Removes the staged card when it goes away.
struct RemotePairingScreen: View {
    @State private var viewModel: RemotePairingViewModel

    init(context: RemotePairingContext, dependencies: FeatureDependencies) {
        let file = RemotePairingViewModel.readFile(at: context.fileURL)
        let viewModel = RemotePairingViewModel(
            service: dependencies.team,
            identity: dependencies.actions.spaceIdentity,
            file: file
        )
        if file == nil {
            viewModel.fail(RemotePairingCopy.unreadableFile)
        }
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        RemotePairingSheet(viewModel: viewModel)
            .onDisappear { viewModel.close() }
    }
}
