import VaultCore

/// A place's edits saved together (1.0 N2, the notes' Review): one transaction applies the
/// deletions, then the renames and new values, then the additions, so a name freed in the save can
/// be taken in it. Values are normalized on the way in (D32); the caller wipes its own (``wipe()``).
public struct PlaceItemEditsModel: Sendable {
    /// An existing item's new name and new value; nil keeps it.
    public struct Change: Sendable {
        public let id: ConfigItemID
        public let name: String?
        public let value: SecretBytes?

        public init(id: ConfigItemID, name: String? = nil, value: SecretBytes? = nil) {
            self.id = id
            self.name = name
            self.value = value
        }
    }

    public struct Addition: Sendable {
        public let kind: ConfigKind
        public let name: String
        public let value: SecretBytes

        public init(kind: ConfigKind, name: String, value: SecretBytes) {
            self.kind = kind
            self.name = name
            self.value = value
        }
    }

    public let deletions: [ConfigItemID]
    public let changes: [Change]
    public let additions: [Addition]

    public init(deletions: [ConfigItemID] = [], changes: [Change] = [], additions: [Addition] = []) {
        self.deletions = deletions
        self.changes = changes
        self.additions = additions
    }

    public var count: Int {
        deletions.count + changes.count + additions.count
    }

    /// Wipes every value.
    public func wipe() {
        for change in changes {
            change.value?.wipe()
        }
        for addition in additions {
            addition.value.wipe()
        }
    }
}

extension PlaceItemEditsModel {
    /// The same edits with every value normalized into a new buffer (D32). The caller wipes them.
    func normalized() throws(ConfigRepositoryError) -> PlaceItemEditsModel {
        var made: [SecretBytes] = []
        func normalize(_ value: SecretBytes) throws(ConfigRepositoryError) -> SecretBytes {
            do {
                let normalized = try ValueNormalizer.normalize(value).value
                made.append(normalized)
                return normalized
            } catch {
                throw .validation(error)
            }
        }
        do {
            let changes = try changes.map { change throws(ConfigRepositoryError) in
                Change(id: change.id, name: change.name, value: try change.value.map { value throws(ConfigRepositoryError) in try normalize(value) })
            }
            let additions = try additions.map { addition throws(ConfigRepositoryError) in
                Addition(kind: addition.kind, name: addition.name, value: try normalize(addition.value))
            }
            return PlaceItemEditsModel(deletions: deletions, changes: changes, additions: additions)
        } catch {
            for value in made {
                value.wipe()
            }
            throw error
        }
    }
}
