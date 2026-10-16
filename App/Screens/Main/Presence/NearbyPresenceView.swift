import SwiftUI

/// Teammates nearby (v0.5.0, T5): an avatar stack in the main window's toolbar, next to Sync.
/// One circle with initials per person (a dot for teammates), "+N" after
/// ``Theme/Layout/presenceMaxBubbles``. A person scales in when seen; a ping from them bounces
/// their bubble. A click opens ``NearbyPersonPopover`` (Ping, Chat).
struct NearbyPresenceView: View {
    @Bindable var presence: TeamPresenceManager
    /// "Got v9 from Ana" (v0.6.0), when a teammate's version arrived.
    var spaceSync: SpaceSyncManager?

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
            HStack(spacing: -Theme.Layout.presenceOverlap) {
                ForEach(people.prefix(Theme.Layout.presenceMaxBubbles)) { person in
                    NearbyBubble(person: person, presence: presence)
                        .transition(.scale.combined(with: .opacity))
                }
                if people.count > Theme.Layout.presenceMaxBubbles {
                    NearbyOverflowBubble(people: Array(people.dropFirst(Theme.Layout.presenceMaxBubbles)), presence: presence)
                }
            }
        }
        .animation(Theme.Durations.spring, value: people.map(\.id))
        .animation(Theme.Durations.interactionAnimation, value: presence.feedback)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "presence.accessibility", defaultValue: "People nearby"))
    }
}

/// One person's circle.
private struct NearbyBubble: View {
    let person: NearbyPersonModel
    @Bindable var presence: TeamPresenceManager

    var body: some View {
        Button {
            presence.popoverPersonID = person.id
        } label: {
            NearbyAvatar(person: person)
        }
        .buttonStyle(.plain)
        .phaseAnimator([1.0, 1.25, 0.95, 1.0], trigger: bounceTrigger) { content, scale in
            content.scaleEffect(scale)
        } animation: { _ in
            Theme.Durations.spring
        }
        .help(person.isTeammate
            ? String(localized: "presence.teammate.help", defaultValue: "\(person.name), your teammate, is nearby")
            : String(localized: "presence.nearby.help", defaultValue: "\(person.name) is nearby"))
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            NearbyPersonPopover(person: person, presence: presence)
        }
    }

    /// Changes only for this bubble's pings.
    private var bounceTrigger: Int {
        presence.bouncingPersonID == person.id ? presence.bounceCount : 0
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { presence.popoverPersonID == person.id },
            set: { if !$0, presence.popoverPersonID == person.id { presence.popoverPersonID = nil } }
        )
    }
}

/// Initials in a circle; teammates get a dot.
struct NearbyAvatar: View {
    let person: NearbyPersonModel

    var body: some View {
        Text(verbatim: person.initials)
            .font(Theme.Typography.monoLabel)
            .foregroundStyle(Theme.Colors.ink)
            .frame(width: Theme.Layout.avatarSize, height: Theme.Layout.avatarSize)
            .background(Theme.Colors.surface2, in: Circle())
            .overlay(Circle().strokeBorder(Theme.Colors.ground, lineWidth: Theme.Stroke.emphasis))
            .overlay(alignment: .bottomTrailing) {
                if person.isTeammate {
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

/// "+N": the people beyond the stack, each with its own row.
private struct NearbyOverflowBubble: View {
    let people: [NearbyPersonModel]
    @Bindable var presence: TeamPresenceManager
    @State private var isShowingList = false

    var body: some View {
        Button {
            isShowingList = true
        } label: {
            Text(verbatim: "+\(people.count)")
                .font(Theme.Typography.monoLabel)
                .foregroundStyle(Theme.Colors.mutedText)
                .frame(width: Theme.Layout.avatarSize, height: Theme.Layout.avatarSize)
                .background(Theme.Colors.surface, in: Circle())
                .overlay(Circle().strokeBorder(Theme.Colors.hairlineStrong, lineWidth: Theme.Stroke.hairline))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(people) { person in
                    Button {
                        isShowingList = false
                        presence.popoverPersonID = nil
                        presence.chat(with: person)
                    } label: {
                        HStack(spacing: Theme.Spacing.mediumMinus) {
                            NearbyAvatar(person: person)
                            Text(verbatim: person.name)
                                .fxTextStyle(.callout)
                                .foregroundStyle(Theme.Colors.ink)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.large)
            .frame(width: Theme.Layout.presencePopoverWidth)
        }
    }
}

/// A person's popover: name, Mac, teammate or nearby, and Ping (teammates) and Chat.
struct NearbyPersonPopover: View {
    let person: NearbyPersonModel
    let presence: TeamPresenceManager

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
