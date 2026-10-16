import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// Preferences › Teammates (v0.5.0, T2, T4, T6): who sees this Mac, the paired devices (Mute,
/// Remove…), Mute all pings, and Add Teammate; since v0.6.0 (Q4) shared-scope sync with
/// teammates outside the local network: off per teammate until turned on, an optional address,
/// and the port this Mac listens on.
@Observable
final class TeammatesSettingsViewModel: LockObserving {
    private(set) var teammates: [TeammateModel] = []
    /// Remote space sync per teammate (v0.6.0).
    private(set) var remoteAccess: [String: TeammateRemoteAccessModel] = [:]
    /// Address fields being edited, by teammate.
    var addressDrafts: [String: String] = [:]
    /// The listener port field.
    var portText = ""
    /// The teammate waiting for the "Remove?" confirmation.
    var pendingRemoval: TeammateModel?
    /// The open Add Teammate sheet.
    var addTeammate: AddTeammateViewModel?
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let app: AppViewModel
    @ObservationIgnored private let tasks = TaskBag()

    init(app: AppViewModel) {
        self.app = app
        portText = String(app.container.preferences.remoteSpacePort)
        app.addLockObserver(self)
        observe()
        observeRemoteAccess()
    }

    var isUnlocked: Bool {
        app.phase == .unlocked
    }

    var visibility: NearbyVisibility {
        get { app.container.preferences.nearbyVisibility }
        set { app.setNearbyVisibility(newValue) }
    }

    var mutesAllPings: Bool {
        get { app.container.preferences.mutesAllPings }
        set { app.container.preferences.mutesAllPings = newValue }
    }

    private var team: TeamRepository {
        app.container.data.team
    }

    private func observe() {
        let stream = team.observeTeammates()
        tasks.set("teammates", Task { [weak self] in
            do {
                for try await teammates in stream {
                    self?.teammates = teammates
                }
            } catch {
                return
            }
        })
    }

    // MARK: - Outside this network (v0.6.0, Q4)

    private func observeRemoteAccess() {
        let stream = team.observeRemoteAccess()
        tasks.set("remote", Task { [weak self] in
            do {
                for try await access in stream {
                    guard let self else { return }
                    self.remoteAccess = Dictionary(access.map { ($0.deviceID, $0) }, uniquingKeysWith: { first, _ in first })
                    for item in access where self.addressDrafts[item.deviceID] == nil {
                        self.addressDrafts[item.deviceID] = item.address?.text ?? ""
                    }
                }
            } catch {
                return
            }
        })
    }

    func isRemoteAllowed(_ teammate: TeammateModel) -> Bool {
        remoteAccess[teammate.id]?.isAllowed == true
    }

    /// Turns remote space sync with the teammate on or off (its address stays).
    func setRemoteAllowed(_ isAllowed: Bool, _ teammate: TeammateModel) {
        do {
            try team.setRemoteAccess(teammate.id, isAllowed: isAllowed, address: remoteAccess[teammate.id]?.address)
        } catch {
            alert = error.presentation
        }
    }

    /// Stores the typed address (`host:port`, or empty to only accept the teammate's
    /// connections).
    func commitAddress(_ teammate: TeammateModel) {
        let text = (addressDrafts[teammate.id] ?? "").trimmingCharacters(in: .whitespaces)
        let address: TeamRemoteAddressModel?
        if text.isEmpty {
            address = nil
        } else if let parsed = TeamRemoteAddressModel(text: text) {
            address = parsed
        } else {
            alert = TeammatesCopy.invalidAddress
            return
        }
        guard address != remoteAccess[teammate.id]?.address else { return }
        do {
            try team.setRemoteAccess(teammate.id, isAllowed: isRemoteAllowed(teammate), address: address)
        } catch {
            alert = error.presentation
        }
    }

    /// Stores the listener port (1–65535) and reopens the listener on it.
    func commitPort() {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)), port > 0 else {
            portText = String(app.container.preferences.remoteSpacePort)
            alert = TeammatesCopy.invalidPort
            return
        }
        guard port != app.container.preferences.remoteSpacePort else { return }
        app.container.preferences.remoteSpacePort = port
        app.spaceSync.remotePortChanged()
    }

    /// Why the listener cannot run (the port is taken), or nil.
    var remoteFailureText: String? {
        app.spaceSync.remoteFailure == nil ? nil : TeammatesCopy.portUnavailable(app.container.preferences.remoteSpacePort)
    }

    /// "Synced over the network 5 min ago", or nil.
    func remoteSummary(_ teammate: TeammateModel) -> String? {
        guard let date = remoteAccess[teammate.id]?.lastConnectedAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return TeammatesCopy.remoteLastSync(formatter.localizedString(for: date, relativeTo: app.container.clock.now))
    }

    func setMuted(_ isMuted: Bool, _ teammate: TeammateModel) {
        do {
            try team.setMuted(isMuted, teammate: teammate.id)
        } catch {
            alert = error.presentation
        }
    }

    /// Removes the teammate; this Mac gets a new announce key, so the removed device stops
    /// recognizing it (the others get the new card when they are next nearby).
    func confirmRemoval() {
        guard let teammate = pendingRemoval else { return }
        pendingRemoval = nil
        do {
            try team.removeTeammate(id: teammate.id)
            app.teamPresence.start()
        } catch {
            alert = error.presentation
        }
    }

    func startAddingTeammate() {
        guard isUnlocked else { return }
        let model = AddTeammateViewModel(app: app)
        addTeammate = model
        Task { await model.start() }
    }

    func addTeammateDismissed() {
        addTeammate?.close()
        addTeammate = nil
    }

    func vaultDidLock() {
        pendingRemoval = nil
        addTeammate?.close()
        addTeammate = nil
    }

    /// "Seen 5 min ago", "Never seen nearby".
    func lastSeenText(_ teammate: TeammateModel) -> String {
        guard let lastSeen = teammate.lastSeenAt else {
            return String(localized: "teammates.lastSeen.never", defaultValue: "Not seen nearby yet")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        let relative = formatter.localizedString(for: lastSeen, relativeTo: app.container.clock.now)
        return String(localized: "teammates.lastSeen", defaultValue: "Seen nearby \(relative)")
    }
}

/// Texts of Preferences › Teammates › Outside this network (v0.6.0, Q4).
enum TeammatesCopy {
    static let remoteSection = String(localized: "settings.teammates.remote.section", defaultValue: "Outside this network")

    static func remoteFootnote(port: UInt16) -> String {
        String(
            localized: "settings.teammates.remote.footnote",
            defaultValue: "Shared scopes also sync with the teammates you turn on here when you are not nearby, for example over Tailscale. Turn it on for each other on both Macs. Only shared-scope sync uses it: no pings, no chat. This Mac listens on TCP port \(String(port)), never advertises it, and answers only the teammates turned on here after they prove their key; five failed attempts close it for 10 minutes. Use a private network; do not open the port to the internet."
        )
    }

    static let port = String(localized: "settings.teammates.remote.port", defaultValue: "Listen on port")
    static let allow = String(localized: "settings.teammates.remote.allow", defaultValue: "Sync shared scopes outside this network")
    static let address = String(localized: "settings.teammates.remote.address", defaultValue: "Their address")
    static let addressPrompt = String(localized: "settings.teammates.remote.address.prompt", defaultValue: "host:port (optional)")

    static func remoteLastSync(_ relative: String) -> String {
        String(localized: "settings.teammates.remote.lastSync", defaultValue: "Synced outside this network \(relative)")
    }

    static func portUnavailable(_ port: UInt16) -> String {
        String(
            localized: "settings.teammates.remote.portUnavailable",
            defaultValue: "FX Vault can't listen on port \(port). Another app may use it; choose another port."
        )
    }

    static let invalidAddress = ErrorPresentationModel(
        title: String(localized: "settings.teammates.remote.invalidAddress.title", defaultValue: "Check the address"),
        message: String(
            localized: "settings.teammates.remote.invalidAddress.message",
            defaultValue: "Type the teammate's host name or IP address and port, like mac-a.example.ts.net:52731."
        )
    )

    static let invalidPort = ErrorPresentationModel(
        title: String(localized: "settings.teammates.remote.invalidPort.title", defaultValue: "Check the port"),
        message: String(localized: "settings.teammates.remote.invalidPort.message", defaultValue: "Choose a port from 1 to 65535.")
    )
}

nonisolated extension TeamRepositoryError: PresentableError {
    var errorPresentation: ErrorPresentationModel {
        switch self {
        case .vault(.locked):
            ErrorPresentationModel(
                title: String(localized: "teammates.error.locked.title", defaultValue: "FX Vault is locked"),
                message: String(localized: "teammates.error.locked.message", defaultValue: "Unlock FX Vault to change your teammates.")
            )
        case .teammateNotFound:
            ErrorPresentationModel(
                title: String(localized: "teammates.error.notFound.title", defaultValue: "Teammate not found"),
                message: String(localized: "teammates.error.notFound.message", defaultValue: "This teammate was already removed.")
            )
        case .keys(let error):
            SharingError.share(error).errorPresentation
        case .vault, .store, .unexpected:
            ErrorPresentationModel(
                title: String(localized: "teammates.error.title", defaultValue: "Couldn't update your teammates"),
                message: String(localized: "teammates.error.message", defaultValue: "Nothing was changed. Try again.")
            )
        }
    }
}
