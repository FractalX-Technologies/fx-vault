import Foundation
import GitHubKit
import os
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Shared spaces in the app (v0.6.0, tasks/todo.md S1, S6, S7, Q4): sharing a scope, versions
/// travelling between two Macs over the fake nearby network, the pull back towards a teammate
/// who is ahead, the space sheet, and remote access in Preferences.
@MainActor
@Suite("Shared spaces in the app", .serialized)
struct SpaceSyncTests {
    @MainActor
    final class Mac {
        let name: String
        let harness: TestHarness
        let keys: TeamDeviceKeys
        let recorder = ActionRecorder()

        init(_ name: String, network: FakeNearbyNetwork, remote: (any SpaceRemoteNetworking)? = nil) async throws {
            self.name = name
            harness = try await TestHarness(
                vault: .unlocked,
                ghStatus: nil,
                teamNetworking: network.networking(for: name),
                spaceNetworking: remote ?? InertSpaceRemoteNetworking()
            )
            harness.preferences.nearbyDisplayName = name
            keys = try harness.data.team.deviceKeys()
        }

        var card: TeamCardModel {
            keys.card(login: name.lowercased(), displayName: name, macName: "\(name)'s Mac")
        }

        var spaceSync: SpaceSyncManager {
            harness.app.spaceSync
        }

        func pair(with other: Mac) throws {
            try harness.data.team.addTeammate(other.card)
        }

        /// Imports `Example-Org/example-repo` (no items) through gh, which answers the marker
        /// reads and writes from `marker` (one GitHub for every Mac).
        func importRepository(marker: SharedMarker) async throws -> RepoID {
            try harness.installFakeGH()
            harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
            harness.stubToken()
            harness.runner.stub(
                argumentsPrefix: ["repo", "view"],
                with: .success(TestFixtures.repoJSON(owner: TestFixtures.owner, name: TestFixtures.repoName, permission: "ADMIN"))
            )
            harness.runner.stub(argumentsPrefix: ["secret", "list"], with: .success("[]"))
            harness.runner.stub(argumentsPrefix: ["api"], with: .success(#"[{"total_count":0,"environments":[]}]"#))
            harness.runner.respond(argumentsPrefix: ["variable", "set"]) { invocation in
                if invocation.arguments.dropFirst(2).first == GitHubNameValidator.spaceMarkerName {
                    marker.set(String(decoding: invocation.stdin, as: UTF8.self))
                }
                return .success("")
            }
            harness.runner.respond(argumentsPrefix: ["variable", "list"]) { _ in
                .success(marker.listing())
            }
            await harness.app.refreshGHStatus()
            let ref = try GHRepoRef(owner: TestFixtures.owner, name: TestFixtures.repoName)
            return try await harness.data.catalog.importRepository(ref, accountLogin: TestFixtures.account).repository.id
        }

        func start() {
            harness.app.teamPresence.start()
            harness.app.spaceSync.start()
            harness.app.teamPresence.setBrowsing(true)
        }

        func dependencies(isGitHubReady: Bool = true) -> FeatureDependencies {
            harness.dependencies(recorder: recorder, isGitHubReady: isGitHubReady)
        }
    }

    /// The `FXVAULT_SPACE` variable of the repository on the simulated GitHub.
    final class SharedMarker: Sendable {
        private let value = OSAllocatedUnfairLock<String?>(initialState: nil)

        func set(_ text: String) {
            value.withLock { $0 = text }
        }

        /// `gh variable list --json` with the marker, or none.
        func listing() -> String {
            guard let text = value.withLock({ $0 }) else { return "[]" }
            let row: [String: String] = [
                "name": GitHubNameValidator.spaceMarkerName,
                "value": text,
                "updatedAt": "2026-10-01T00:00:00Z",
                "createdAt": "2026-10-01T00:00:00Z",
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: [row]) else { return "[]" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Ana and Ben, paired, browsing, both with the repository; Ana can reach gh.
    static func pairedMacs() async throws -> (FakeNearbyNetwork, Mac, Mac, RepoID, RepoID) {
        let network = FakeNearbyNetwork()
        let ana = try await Mac("Ana", network: network)
        let ben = try await Mac("Ben", network: network)
        try ana.pair(with: ben)
        try ben.pair(with: ana)
        let marker = SharedMarker()
        let anaRepo = try await ana.importRepository(marker: marker)
        let benRepo = try await ben.importRepository(marker: marker)
        ana.start()
        ben.start()
        return (network, ana, ben, anaRepo, benRepo)
    }

    @Test func sharingFromTheSheetReachesTheTeammateMacToMac() async throws {
        let (_, ana, ben, anaRepo, benRepo) = try await Self.pairedMacs()
        let share = ShareSpaceViewModel(
            context: ShareSpaceContext(repositoryID: anaRepo, scope: .repository),
            dependencies: ana.dependencies()
        )
        share.load()
        #expect(share.isReady)
        #expect(share.teammates.map(\.name) == ["Ben"])
        #expect(!share.canShare)
        share.toggle(ben.keys.deviceID.hex)
        #expect(share.canShare)

        await share.share()

        let spaceID = try #require(share.sharedSpaceID)
        #expect(share.alert == nil)
        #expect(ana.recorder.spacePublishes == 1)
        #expect(try ana.harness.data.spaces.spaces().map(\.id) == [spaceID])
        #expect(try ana.harness.data.spaces.spaces().map(\.isPublishing) == [false])
        #expect(ana.harness.runner.invocations.contains { $0.arguments.starts(with: ["variable", "set", GitHubNameValidator.spaceMarkerName]) })

        // Ana tells Ben; Ben sees a space it does not have and pulls it back from Ana.
        ana.spaceSync.syncAll()
        #expect(await TestFixtures.eventually { (try? ben.harness.data.spaces.spaces().map(\.id)) == [spaceID] })
        let benSpace = try #require(try ben.harness.data.spaces.spaces().first)
        #expect(benSpace.repositoryID == benRepo)
        #expect(await TestFixtures.eventually { ben.spaceSync.latestNotice?.version == 1 })
        #expect(ben.spaceSync.latestNotice?.text == "Got v1 from Ana")
    }

    @Test func getUpdatesFromTeammatesPullsAndWaits() async throws {
        let (_, ana, ben, anaRepo, _) = try await Self.pairedMacs()
        let spaceID = try await ana.harness.data.spaces.share(
            repositoryID: anaRepo,
            scope: .repository,
            with: [ben.keys.deviceID.hex],
            me: SpaceLocalIdentityModel(login: "ana", displayName: "Ana", macName: "Ana's Mac"),
            reason: ""
        )
        ana.spaceSync.syncAll()
        #expect(await TestFixtures.eventually { (try? ben.harness.data.spaces.spaces().count) == 1 })

        // A member change on Ana's side (v2) reaches Ben when he asks for updates.
        let cara = try await Mac("Cara", network: FakeNearbyNetwork())
        try ana.pair(with: cara)
        try await ana.harness.data.spaces.addMembers(
            spaceID,
            teammateIDs: [cara.keys.deviceID.hex],
            me: SpaceLocalIdentityModel(login: "ana", displayName: "Ana", macName: "Ana's Mac")
        )
        await ben.spaceSync.syncAllAndWait()
        #expect(try ben.harness.data.spaces.detail(spaceID).members.map(\.name) == ["Ana", "Ben", "Cara"])
    }

    @Test func theSpaceSheetShowsHistoryMembersAndRevealsAfterThePassword() async throws {
        let (_, ana, ben, anaRepo, _) = try await Self.pairedMacs()
        let spaceID = try await ana.harness.data.spaces.share(
            repositoryID: anaRepo,
            scope: .repository,
            with: [ben.keys.deviceID.hex],
            me: SpaceLocalIdentityModel(login: "ana", displayName: "Ana", macName: "Ana's Mac"),
            reason: "Start sharing"
        )
        let model = SpaceViewModel(context: SpaceContext(spaceID: spaceID), dependencies: ana.dependencies())
        model.load()
        #expect(model.scopeName == "Repository")
        #expect(model.subtitle == "v1 · 2 members")
        #expect(model.history.map(\.version) == [1])
        #expect(model.history.first?.reason == "Start sharing")
        #expect(model.detail?.members.map(\.name) == ["Ana", "Ben"])
        #expect(model.detail?.members.map(\.isThisMac) == [true, false])
        #expect(model.addableTeammates.isEmpty)
        #expect(model.canChangeMembers)

        model.pendingRemoval = model.detail?.members.last
        await model.confirmRemoval()
        #expect(model.alert == nil)
        #expect(model.notice == SpaceCopy.rotationChecklist([]))
        #expect(model.detail?.members.map(\.name) == ["Ana"])
        #expect(ana.recorder.spacePublishes == 1)
    }

    @Test func remoteAccessStartsTheListenerOnlyForAllowedTeammates() async throws {
        let network = FakeNearbyNetwork()
        let remote = RecordedSpaceRemoteNetworking()
        let ana = try await Mac("Ana", network: network, remote: remote)
        let ben = try await Mac("Ben", network: network)
        try ana.pair(with: ben)
        ana.start()
        #expect(remote.listenerPorts.isEmpty)

        let settings = TeammatesSettingsViewModel(app: ana.harness.app)
        #expect(await TestFixtures.eventually { settings.teammates.count == 1 })
        let teammate = try #require(settings.teammates.first)
        #expect(!settings.isRemoteAllowed(teammate))
        settings.setRemoteAllowed(true, teammate)
        #expect(await TestFixtures.eventually { remote.listenerPorts == [TeamProtocol.defaultRemotePort] })

        settings.addressDrafts[teammate.id] = "not an address"
        settings.commitAddress(teammate)
        #expect(settings.alert == TeammatesCopy.invalidAddress)
        settings.alert = nil
        settings.addressDrafts[teammate.id] = "mac-b.example:9000"
        settings.commitAddress(teammate)
        #expect(await TestFixtures.eventually { settings.remoteAccess[teammate.id]?.address?.text == "mac-b.example:9000" })

        settings.portText = "9100"
        settings.commitPort()
        #expect(ana.harness.preferences.remoteSpacePort == 9100)
        #expect(await TestFixtures.eventually { remote.listenerPorts == [TeamProtocol.defaultRemotePort, 9100] })

        settings.setRemoteAllowed(false, teammate)
        #expect(await TestFixtures.eventually { remote.stoppedCount == 2 })

        ana.harness.app.lock(trigger: .manual)
        #expect(ana.spaceSync.activeTeammates.isEmpty)
    }
}

/// Records the listeners the space sync opened (no network).
final class RecordedSpaceRemoteNetworking: SpaceRemoteNetworking {
    private(set) var listenerPorts: [UInt16] = []
    private(set) var stoppedCount = 0

    func makeListener(port: UInt16) -> any SpaceRemoteListening {
        listenerPorts.append(port)
        return RecordedSpaceListener { [weak self] in self?.stoppedCount += 1 }
    }

    func connect(to address: TeamRemoteAddressModel) -> (any NearbyTransport)? {
        nil
    }
}

final class RecordedSpaceListener: SpaceRemoteListening {
    let connections = AsyncStream<RemoteSpaceConnectionModel> { _ in }
    let failures = AsyncStream<NearbyTransportFailure> { _ in }
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
    }

    func start() {}

    func stop() {
        onStop()
    }

    func recordFailedSession() {}
}
