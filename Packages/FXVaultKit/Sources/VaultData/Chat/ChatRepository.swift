import Foundation
import SharingKit
import VaultCore
import VaultStore

/// Nearby chat (v0.2.0, experimental; SHARING-PROTOCOL.md "Nearby chat"): the conversations
/// the chat window runs and the vault items that can be attached to them.
///
/// Chat is 1:1 and ephemeral: nothing here touches the disk except reading item names and,
/// when the user asks, decrypting the one attached value or importing a received one through
/// the normal share import (``SharingRepository``).
public struct ChatRepository: Sendable {
    private let session: VaultSession
    private let sharing: SharingRepository
    private let clock: any VaultClock
    private let builder: ShareExportBuilder

    public init(session: VaultSession, sharing: SharingRepository, clock: any VaultClock = SystemClock()) {
        self.session = session
        self.sharing = sharing
        self.clock = clock
        builder = ShareExportBuilder(session: session, clock: clock)
    }

    /// Every live secret and variable with a local value, by repository (`owner/name`), then
    /// repository level before environments (by name), then kind and name. Names only.
    ///
    /// - Throws: `.sharing(.vault(.locked))` while locked, `.sharing(.store)`.
    public func attachableItems() throws(NearbyChatError) -> [ChatAttachableItemModel] {
        let database = session.database
        do {
            return try performSharing {
                try session.read { _, tx in
                    let config = ConfigStore(database: database)
                    var items: [ChatAttachableItemModel] = []
                    for repository in try RepoStore(database: database).fetchAll(in: tx) {
                        let environments = try config.fetchEnvironments(repositoryID: repository.id, in: tx)
                            .filter { !$0.isDeleted }
                        let names = Dictionary(
                            environments.map { ($0.id, $0.name) },
                            uniquingKeysWith: { first, _ in first }
                        )
                        for record in try config.fetchItemRecords(repositoryID: repository.id, in: tx)
                        where !record.isDeleted && record.valueCiphertext != nil {
                            let environmentName = record.environmentID.flatMap { names[$0] }
                            if record.environmentID != nil, environmentName == nil { continue }
                            items.append(ChatAttachableItemModel(
                                id: record.id,
                                repositoryID: repository.id,
                                kind: record.kind,
                                name: record.name,
                                repositoryFullName: "\(repository.ownerLogin)/\(repository.name)",
                                environmentName: environmentName
                            ))
                        }
                    }
                    return items.sorted(by: Self.pickerOrder)
                }
            }
        } catch {
            throw .sharing(error)
        }
    }

    /// Every repository with at least one environment or item, by `owner/name`: what a whole
    /// configuration attachment can send (v0.4.0). Names and counts only.
    ///
    /// - Throws: `.sharing(.vault(.locked))` while locked, `.sharing(.store)`.
    public func attachableRepositories() throws(NearbyChatError) -> [ChatAttachableRepositoryModel] {
        let database = session.database
        do {
            return try performSharing {
                try session.read { _, tx in
                    let config = ConfigStore(database: database)
                    return try RepoStore(database: database).fetchAll(in: tx).compactMap { repository in
                        let environments = try config.fetchEnvironments(repositoryID: repository.id, in: tx)
                            .filter { !$0.isDeleted }
                        let live = Set(environments.map(\.id))
                        let items = try config.fetchItemRecords(repositoryID: repository.id, in: tx).filter { record in
                            !record.isDeleted && (record.environmentID.map(live.contains) ?? true)
                        }
                        guard !environments.isEmpty || !items.isEmpty else { return nil }
                        return ChatAttachableRepositoryModel(
                            id: repository.id,
                            fullName: "\(repository.ownerLogin)/\(repository.name)",
                            environmentCount: environments.count,
                            itemCount: items.count
                        )
                    }
                    .sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
                }
            }
        } catch {
            throw .sharing(error)
        }
    }

    /// The repositories of this vault, by `owner/name`: where "Import Into…" can import a
    /// configuration received in chat (v0.4.0).
    ///
    /// - Throws: `.sharing(.vault(.locked))` while locked, `.sharing(.store)`.
    public func importTargets() throws(NearbyChatError) -> [RepoModel] {
        let database = session.database
        do {
            return try performSharing {
                try session.read { _, tx in
                    try RepoStore(database: database).fetchAll(in: tx)
                        .sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
                }
            }
        } catch {
            throw .sharing(error)
        }
    }

    /// One chat over `transport` (an `NWNearbyTransport` the app connected or advertised, or an
    /// in-memory one in tests). A conversation runs once; a new chat needs a new one.
    ///
    /// - Parameters:
    ///   - role: `.initiator` connected to a browsed peer; `.responder` advertises.
    ///   - localName: this Mac's display name (sanitized before it is sent).
    public func makeConversation(
        role: NearbyRole,
        transport: any NearbyTransport,
        localName: String,
        clock: (any VaultClock)? = nil
    ) -> NearbyChatConversation {
        NearbyChatConversation(
            session: NearbyChatSession(
                role: role,
                localName: DisplayNameSanitizer.sanitize(localName),
                transport: transport,
                clock: clock ?? self.clock
            ),
            vault: session,
            builder: builder,
            sharing: sharing
        )
    }

    private static func pickerOrder(_ lhs: ChatAttachableItemModel, _ rhs: ChatAttachableItemModel) -> Bool {
        sortKey(lhs) < sortKey(rhs)
    }

    /// Repository, then repository level (0) before environments (1) by name, then kind and name.
    private static func sortKey(_ item: ChatAttachableItemModel) -> (String, Int, String, String, String) {
        (
            item.repositoryFullName.lowercased(),
            item.environmentName == nil ? 0 : 1,
            item.environmentName?.lowercased() ?? "",
            item.kind.rawValue,
            item.name
        )
    }
}
