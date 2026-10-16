import SwiftUI
import VaultCore

/// Teammates nearby in the toolbar (v0.5.0, T5; compact since v0.7.0, N2): the latest ping or
/// shared-scope notice, then one people button with the number of people nearby. Its popover
/// lists them with Ping and Chat; the sidebar's TEAMMATES section lists every teammate. A ping
/// bounces the button.
struct NearbyPresenceView: View {
    @Bindable var presence: TeamPresenceManager
    /// "Got v9 from Ana" (v0.6.0), when a teammate's version arrived.
    var spaceSync: SpaceSyncManager?
    @State private var isShowingList = false

    var body: some View {
        let people = presence.people
        HStack(spacing: Theme.Spacing.small) {
            if presence.feedback == nil, let notice = spaceSync?.latestNotice {
                Text(notice.text)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .help(notice.text)
                    .transition(.opacity)
            }
            if let feedback = presence.feedback {
                Text(feedback.text)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Button {
                isShowingList = true
            } label: {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Image(systemName: people.isEmpty ? "person.2" : "person.2.fill")
                        .font(Theme.Typography.caption)
                    Text(verbatim: "\(people.count)")
                        .font(Theme.Typography.monoLabel)
                }
                .foregroundStyle(people.isEmpty ? Theme.Colors.subtleText : Theme.Colors.ink)
                .padding(.horizontal, Theme.Spacing.small)
                .frame(height: Theme.Layout.avatarSize)
                .overlay(Capsule.pill.strokeBorder(Theme.Colors.hairlineStrong, lineWidth: Theme.Stroke.hairline))
                .contentShape(Capsule.pill)
            }
            .buttonStyle(.plain)
            .phaseAnimator([1.0, 1.25, 0.95, 1.0], trigger: presence.bounceCount) { content, scale in
                content.scaleEffect(scale)
            } animation: { _ in
                Theme.Durations.spring
            }
            .help(NearbyPresenceCopy.help(count: people.count))
            .accessibilityLabel(NearbyPresenceCopy.help(count: people.count))
            .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
                NearbyPeopleList(people: people, presence: presence) {
                    isShowingList = false
                }
            }
        }
        .animation(Theme.Durations.interactionAnimation, value: presence.feedback)
    }
}

/// The people nearby with Ping (teammates) and Chat; an empty list says how teammates appear.
struct NearbyPeopleList: View {
    let people: [NearbyPersonModel]
    let presence: TeamPresenceManager
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(NearbyPresenceCopy.listTitle)
            if people.isEmpty {
                Text(NearbyPresenceCopy.empty)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(people) { person in
                HStack(spacing: Theme.Spacing.mediumMinus) {
                    NearbyAvatar(person: person)
                    Text(verbatim: person.name)
                        .fxTextStyle(.callout)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if person.isTeammate {
                        Button(String(localized: "presence.ping", defaultValue: "Ping")) {
                            presence.ping(person)
                            onDone()
                        }
                        .fxButtonStyle(.outline)
                        .disabled(!presence.canPing(person))
                    }
                    Button(String(localized: "presence.chat", defaultValue: "Chat")) {
                        presence.popoverPersonID = nil
                        presence.chat(with: person)
                        onDone()
                    }
                    .fxButtonStyle(.outline)
                }
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: Theme.Layout.presencePopoverWidth)
    }
}

/// Texts of the toolbar's people button.
enum NearbyPresenceCopy {
    static let listTitle = String(localized: "presence.list.title", defaultValue: "Nearby now")
    static let empty = String(
        localized: "presence.list.empty",
        defaultValue: "Nobody nearby. Teammates appear here, and in the sidebar, while their Mac is close with FX Vault open."
    )

    static func help(count: Int) -> String {
        String(localized: "presence.button.help", defaultValue: "People nearby: \(count)")
    }
}

/// Initials in a circle; teammates get a dot (in the sidebar only while nearby, v0.7.0).
struct NearbyAvatar: View {
    let person: NearbyPersonModel
    var showsDot: Bool?

    var body: some View {
        Text(verbatim: person.initials)
            .font(Theme.Typography.monoLabel)
            .foregroundStyle(Theme.Colors.ink)
            .frame(width: Theme.Layout.avatarSize, height: Theme.Layout.avatarSize)
            .background(Theme.Colors.surface2, in: Circle())
            .overlay(Circle().strokeBorder(Theme.Colors.ground, lineWidth: Theme.Stroke.emphasis))
            .overlay(alignment: .bottomTrailing) {
                if showsDot ?? person.isTeammate {
                    Circle()
                        .fill(Theme.Colors.success)
                        .frame(width: Theme.Layout.statusDotSize, height: Theme.Layout.statusDotSize)
                        .overlay(Circle().strokeBorder(Theme.Colors.ground, lineWidth: Theme.Stroke.hairline))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(person.name)
    }
}

/// A person's popover: name, Mac, teammate or nearby, and Ping (teammates) and Chat; Send
/// Folder (v0.7.0) when there are folders with items.
struct NearbyPersonPopover: View {
    let person: NearbyPersonModel
    let presence: TeamPresenceManager
    var folders: [FolderModel] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.medium) {
                NearbyAvatar(person: person)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: person.name)
                        .fxTextStyle(.headline)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                    Text(detail)
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                StatusChip(
                    title: person.isTeammate
                        ? String(localized: "presence.tag.teammate", defaultValue: "Teammate")
                        : String(localized: "presence.tag.nearby", defaultValue: "Nearby"),
                    tone: person.isTeammate ? .success : .neutral
                )
            }
            if !person.isTeammate {
                Text(String(
                    localized: "presence.stranger.note",
                    defaultValue: "Not a teammate: the name is what their Mac says. A chat starts with the code."
                ))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Spacing.small) {
                if person.isTeammate {
                    Button(pingTitle) {
                        presence.ping(person)
                    }
                    .fxButtonStyle(.outline)
                    .disabled(!presence.canPing(person))
                }
                Button(String(localized: "presence.chat", defaultValue: "Chat")) {
                    presence.chat(with: person)
                }
                .fxButtonStyle(.primary)
                let sendable = folders.filter { $0.itemCount > 0 }
                if !sendable.isEmpty {
                    Menu {
                        ForEach(sendable) { folder in
                            Button(folder.name) {
                                presence.chat(with: person, sendingFolder: folder.id)
                            }
                        }
                    } label: {
                        HStack(spacing: Theme.Spacing.smallMinus) {
                            Text(FolderCopy.sendFolder)
                            Image(systemName: "chevron.down")
                                .font(Theme.Typography.monoLabel)
                                .accessibilityHidden(true)
                        }
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.button)
                    .fxButtonStyle(.outline)
                    .fixedSize()
                    .help(String(
                        localized: "presence.sendFolder.help",
                        defaultValue: "Opens a chat with \(person.name) and attaches the folder after Touch ID or your password. They get their own copy."
                    ))
                }
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: Theme.Layout.presencePopoverWidth)
    }

    private var detail: String {
        if let macName = person.macName, !macName.isEmpty {
            return macName
        }
        return String(localized: "presence.nearbyNow", defaultValue: "Nearby now")
    }

    private var pingTitle: String {
        let cooldown = Int(presence.pingCooldown(for: person).rounded(.up))
        return cooldown > 0
            ? String(localized: "presence.ping.wait", defaultValue: "Ping (\(cooldown) s)")
            : String(localized: "presence.ping", defaultValue: "Ping")
    }
}
