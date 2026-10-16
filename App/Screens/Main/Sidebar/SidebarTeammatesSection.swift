import SwiftUI
import VaultCore

/// One paired teammate in the TEAMMATES section (v0.7.0): nearby now (with the person the
/// presence sees) or not.
struct SidebarTeammateRowModel: Identifiable, Equatable {
    let teammate: TeammateModel
    /// Set while the teammate is nearby.
    let person: NearbyPersonModel?

    var id: String {
        teammate.id
    }

    var isNearby: Bool {
        person != nil
    }

    /// Nearby teammates first, then by name.
    static func rows(teammates: [TeammateModel], people: [NearbyPersonModel]) -> [SidebarTeammateRowModel] {
        teammates
            .map { teammate in
                SidebarTeammateRowModel(teammate: teammate, person: people.first { $0.kind == .teammate(deviceID: teammate.id) })
            }
            .sorted { lhs, rhs in
                if lhs.isNearby != rhs.isNearby { return lhs.isNearby }
                return lhs.teammate.name.localizedCaseInsensitiveCompare(rhs.teammate.name) == .orderedAscending
            }
    }
}

/// TEAMMATES, pinned at the bottom of the sidebar (v0.7.0, tasks/todo.md N1): who can see this
/// Mac (a menu), every paired teammate with a green dot and "Nearby" or when they were last
/// seen, "Others nearby · N", and Add Teammate… when there is none. A click on a teammate opens
/// its popover (Ping, Chat, Send Folder; unavailable with the reason when not nearby).
struct SidebarTeammatesSection: View {
    let main: MainViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let presence = main.app.teamPresence
        let rows = SidebarTeammateRowModel.rows(teammates: main.sidebar.teammates, people: presence.people)
        let others = presence.people.filter { !$0.isTeammate }
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack(spacing: Theme.Spacing.small) {
                SectionLabel(TeammatesSidebarCopy.title)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                VisibilityMenu(main: main)
            }
            .padding(.horizontal, Theme.Spacing.small)
            if rows.isEmpty {
                Text(TeammatesSidebarCopy.emptyHint)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.small)
                Button {
                    addTeammate()
                } label: {
                    Label(TeammatesSidebarCopy.addTeammate, systemImage: "person.badge.plus")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fxRowBackground(isSelected: false, style: .sidebar)
                }
                .buttonStyle(.plain)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                        ForEach(rows) { row in
                            SidebarTeammateRow(row: row, main: main)
                        }
                        if !others.isEmpty {
                            OthersNearbyRow(people: others, main: main)
                        }
                    }
                    .padding(.bottom, Theme.Spacing.small)
                }
                .frame(maxHeight: Theme.Layout.sidebarTeammatesMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.medium)
    }

    private func addTeammate() {
        main.app.requestedPreferencesTab = .teammates
        openSettings()
    }
}

/// Who can see this Mac nearby: an eye (teammates), a crossed eye (nobody) or waves
/// (everyone), with the choices in its menu.
private struct VisibilityMenu: View {
    let main: MainViewModel

    var body: some View {
        let current = main.app.container.preferences.nearbyVisibility
        Menu {
            Picker(TeammatesSidebarCopy.visibility, selection: Binding(
                get: { main.app.container.preferences.nearbyVisibility },
                set: { main.app.setNearbyVisibility($0) }
            )) {
                ForEach(NearbyVisibility.allCases) { visibility in
                    Text(visibility.title).tag(visibility)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: Self.symbol(current))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.mutedText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(TeammatesSidebarCopy.visibilityLabel(current))
        .accessibilityLabel(TeammatesSidebarCopy.visibilityLabel(current))
    }

    private static func symbol(_ visibility: NearbyVisibility) -> String {
        switch visibility {
        case .nobody: "eye.slash"
        case .teammates: "eye"
        case .everyone: "dot.radiowaves.left.and.right"
        }
    }
}

/// One teammate: avatar (a green dot while nearby), name, "Nearby" or the last sighting, the
/// muted bell, and the latest shared-scope notice from them.
private struct SidebarTeammateRow: View {
    let row: SidebarTeammateRowModel
    let main: MainViewModel
    @State private var isShowingAway = false

    var body: some View {
        let presence = main.app.teamPresence
        Button {
            if let person = row.person {
                presence.popoverPersonID = person.id
            } else {
                isShowingAway = true
            }
        } label: {
            HStack(spacing: Theme.Spacing.mediumMinus) {
                NearbyAvatar(person: avatarPerson, showsDot: row.isNearby)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: row.teammate.name)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                    Text(status)
                        .font(Theme.Typography.monoLabel)
                        .foregroundStyle(row.isNearby ? Theme.Colors.success : Theme.Colors.subtleText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if row.teammate.isMuted {
                    Image(systemName: "bell.slash")
                        .font(Theme.Typography.monoLabel)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .help(TeammatesSidebarCopy.muted)
                        .accessibilityLabel(TeammatesSidebarCopy.muted)
                }
            }
            .fxRowBackground(isSelected: false, style: .sidebar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: nearbyPopover, arrowEdge: .trailing) {
            if let person = row.person {
                NearbyPersonPopover(person: person, presence: presence, folders: main.sidebar.folders)
            }
        }
        .popover(isPresented: $isShowingAway, arrowEdge: .trailing) {
            AwayTeammatePopover(row: row, main: main)
        }
    }

    private var avatarPerson: NearbyPersonModel {
        row.person ?? NearbyPersonModel(
            kind: .teammate(deviceID: row.teammate.id),
            name: row.teammate.name,
            macName: row.teammate.macName,
            lastSeenAt: row.teammate.lastSeenAt ?? row.teammate.pairedAt
        )
    }

    private var status: String {
        if let notice = main.app.spaceSync.latestNotice, notice.teammateName == row.teammate.name {
            return notice.text
        }
        return row.isNearby ? TeammatesSidebarCopy.nearby : TeammatesSidebarCopy.lastSeen(row.teammate.lastSeenAt, now: main.app.container.clock.now)
    }

    private var nearbyPopover: Binding<Bool> {
        let presence = main.app.teamPresence
        return Binding(
            get: { row.person.map { presence.popoverPersonID == $0.id } ?? false },
            set: { if !$0, let person = row.person, presence.popoverPersonID == person.id { presence.popoverPersonID = nil } }
        )
    }
}

/// A teammate who is not nearby: when they were last seen and why Ping and Chat wait.
private struct AwayTeammatePopover: View {
    let row: SidebarTeammateRowModel
    let main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: row.teammate.name)
                    .fxTextStyle(.headline)
                    .foregroundStyle(Theme.Colors.ink)
                Text(verbatim: [row.teammate.login, row.teammate.macName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
            Text(TeammatesSidebarCopy.awayNote(row.teammate.lastSeenAt, now: main.app.container.clock.now))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.large)
        .frame(width: Theme.Layout.presencePopoverWidth)
    }
}

/// "Others nearby · N": people who are not teammates (Everyone nearby), each with Chat.
private struct OthersNearbyRow: View {
    let people: [NearbyPersonModel]
    let main: MainViewModel
    @State private var isShowingList = false

    var body: some View {
        Button {
            isShowingList = true
        } label: {
            Label(TeammatesSidebarCopy.others(people.count), systemImage: "person.2.wave.2")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .fxRowBackground(isSelected: false, style: .sidebar)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingList, arrowEdge: .trailing) {
            NearbyPeopleList(people: people, presence: main.app.teamPresence) {
                isShowingList = false
            }
        }
    }
}

/// The TEAMMATES section's texts.
enum TeammatesSidebarCopy {
    static let title = String(localized: "sidebar.teammates", defaultValue: "Teammates")
    static let addTeammate = String(localized: "sidebar.teammates.add", defaultValue: "Add Teammate…")
    static let emptyHint = String(
        localized: "sidebar.teammates.empty",
        defaultValue: "Pair once with a 6-digit code to see each other nearby, ping, chat and send folders."
    )
    static let visibility = String(localized: "sidebar.teammates.visibility", defaultValue: "Who can see this Mac")
    static let nearby = String(localized: "sidebar.teammates.nearby", defaultValue: "Nearby")
    static let muted = String(localized: "sidebar.teammates.muted", defaultValue: "Pings muted")

    static func visibilityLabel(_ visibility: NearbyVisibility) -> String {
        switch visibility {
        case .nobody: String(localized: "sidebar.teammates.visibility.nobody", defaultValue: "Hidden")
        case .teammates: String(localized: "sidebar.teammates.visibility.teammates", defaultValue: "Visible to teammates")
        case .everyone: String(localized: "sidebar.teammates.visibility.everyone", defaultValue: "Visible to everyone")
        }
    }

    static func lastSeen(_ date: Date?, now: Date) -> String {
        guard let date else {
            return String(localized: "sidebar.teammates.neverSeen", defaultValue: "Not seen yet")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return String(localized: "sidebar.teammates.seen", defaultValue: "Seen \(formatter.localizedString(for: date, relativeTo: now))")
    }

    static func awayNote(_ date: Date?, now: Date) -> String {
        String(
            localized: "sidebar.teammates.away",
            defaultValue: "\(lastSeen(date, now: now)). Ping, Chat and Send Folder work when their Mac is nearby with FX Vault open."
        )
    }

    static func others(_ count: Int) -> String {
        String(localized: "sidebar.teammates.others", defaultValue: "Others nearby · \(count)")
    }
}
