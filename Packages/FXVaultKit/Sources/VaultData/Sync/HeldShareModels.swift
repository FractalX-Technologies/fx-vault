import Foundation
import VaultCore

/// One share file whose imported rows wait for Sync's From Files review (v0.9.0, tasks/todo.md
/// P8): who sent it, when, and what it holds back. Names only, never values.
public struct HeldShareModel: Sendable, Hashable, Identifiable {
    public let packageID: SharePackageID
    /// The sender's display name as the file stated it (a passphrase file: unverified).
    public let senderName: String?
    /// The teammate whose device key signed the file (lowercase hex), nil for a passphrase file.
    public let senderDeviceID: String?
    /// The file's `createdAt` as the sender stated it; nil when the import record is missing.
    public let createdAt: Date?
    /// When this Mac imported it; nil when the import record is missing.
    public let importedAt: Date?
    /// Every repository with held rows of this file, in sidebar order.
    public let repositories: [HeldShareRepositoryModel]

    public init(
        packageID: SharePackageID,
        senderName: String?,
        senderDeviceID: String?,
        createdAt: Date?,
        importedAt: Date?,
        repositories: [HeldShareRepositoryModel]
    ) {
        self.packageID = packageID
        self.senderName = senderName
        self.senderDeviceID = senderDeviceID
        self.createdAt = createdAt
        self.importedAt = importedAt
        self.repositories = repositories
    }

    public var id: SharePackageID {
        packageID
    }

    /// True for a teammates file: FX Vault checked the sender's signature when it was opened.
    public var isSenderVerified: Bool {
        senderDeviceID != nil
    }

    /// Held rows across repositories and destinations.
    public var itemCount: Int {
        repositories.map(\.itemCount).reduce(0, +)
    }

    /// Every held row of this file.
    public var itemIDs: Set<ConfigItemID> {
        Set(repositories.flatMap { repository in
            repository.scopes.flatMap { $0.items.map(\.id) } + repository.destinations.flatMap { $0.items.map(\.id) }
        })
    }
}

/// The held rows of one share file in one repository.
public struct HeldShareRepositoryModel: Sendable, Hashable, Identifiable {
    public let repository: RepoModel
    /// Repository level first, then environments in sidebar order.
    public let scopes: [HeldShareScopeModel]
    /// Destinations in sidebar order.
    public let destinations: [HeldShareDestinationModel]

    public init(repository: RepoModel, scopes: [HeldShareScopeModel], destinations: [HeldShareDestinationModel]) {
        self.repository = repository
        self.scopes = scopes
        self.destinations = destinations
    }

    public var id: RepoID {
        repository.id
    }

    public var itemCount: Int {
        scopes.map(\.items.count).reduce(0, +) + destinations.map(\.items.count).reduce(0, +)
    }
}

/// The held rows of one share file in one GitHub scope.
public struct HeldShareScopeModel: Sendable, Hashable, Identifiable {
    public let scope: ConfigScope
    /// The environment's name; nil at repository level.
    public let environmentName: String?
    /// By name.
    public let items: [HeldShareItemModel]
    /// The environment's creation (or rename) waits for this file too: every live item in a new
    /// environment is held, or a renamed environment still holds one of this file's rows.
    public let holdsEnvironment: Bool

    public init(scope: ConfigScope, environmentName: String?, items: [HeldShareItemModel], holdsEnvironment: Bool) {
        self.scope = scope
        self.environmentName = environmentName
        self.items = items
        self.holdsEnvironment = holdsEnvironment
    }

    public var id: String {
        scope.environmentID?.uuidString ?? "repository"
    }
}

/// The held rows of one share file in one destination.
public struct HeldShareDestinationModel: Sendable, Hashable, Identifiable {
    public let destination: DestinationModel
    /// By name.
    public let items: [HeldShareItemModel]

    public init(destination: DestinationModel, items: [HeldShareItemModel]) {
        self.destination = destination
        self.items = items
    }

    public var id: DestinationID {
        destination.id
    }
}

/// One held row: names only.
public struct HeldShareItemModel: Sendable, Hashable, Identifiable {
    public let id: ConfigItemID
    public let kind: ConfigKind
    public let name: String
    /// The remote does not have it yet (an add); false for a new value of an item it has.
    public let isNew: Bool

    public init(id: ConfigItemID, kind: ConfigKind, name: String, isNew: Bool) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isNew = isNew
    }
}
