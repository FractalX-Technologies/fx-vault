import Foundation
import GRDB
import VaultCore

/// Secret and variable names across every holder (1.0 D6c5, ⌘K "Secrets by name"; the quick
/// vault, B10): the live rows of `config_items` (outside deleted environments), `folder_items`,
/// `destination_items` and `org_items`. It selects no value column.
public struct ItemNameStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    /// The items whose name contains every word (upper case, as names are stored): a name that
    /// starts with one first, then by name, secrets before variables; at most `limit`.
    public func fetchMatches(containing words: [String], limit: Int) throws -> [ItemNameMatchModel] {
        guard !words.isEmpty, limit > 0 else { return [] }
        var sql: SQL = """
            SELECT id, kind, name, holder, holder_id, environment_id FROM (
              SELECT i.id, i.kind, i.name, 'scope' AS holder, i.repository_id AS holder_id, i.environment_id
                FROM config_items i LEFT JOIN environments e ON e.id = i.environment_id
                WHERE i.is_deleted = 0 AND (i.environment_id IS NULL OR e.is_deleted = 0)
              UNION ALL
              SELECT id, kind, name, 'folder', folder_id, NULL FROM folder_items
              UNION ALL
              SELECT id, kind, name, 'destination', destination_id, NULL FROM destination_items WHERE is_deleted = 0
              UNION ALL
              SELECT id, kind, name, 'organization', organization_id, NULL FROM org_items WHERE is_deleted = 0)
            WHERE 1
            """
        for word in words {
            sql += " AND instr(name, \(word)) > 0"
        }
        let startsWithAWord = words.map { word -> SQL in "instr(name, \(word)) = 1" }.joined(separator: " OR ")
        sql += " ORDER BY CASE WHEN \(startsWithAWord) THEN 0 ELSE 1 END, name, kind = 'variable', holder, holder_id"
        sql += " LIMIT \(limit)"
        let request = SQLRequest<Row>(literal: sql)
        return try database.read { tx in
            try request.fetchAll(tx.db).compactMap(Self.match)
        }
    }

    private static func match(_ row: Row) -> ItemNameMatchModel? {
        guard let id = (row["id"] as String?).flatMap(ConfigItemID.init(uuidString:)),
              let kind = (row["kind"] as String?).flatMap(ConfigKind.init(rawValue:)),
              let name = row["name"] as String?,
              let holderID = row["holder_id"] as String?
        else { return nil }
        let holder: ItemHolderModel?
        switch row["holder"] as String? {
        case "scope":
            let environmentID = (row["environment_id"] as String?).flatMap(EnvironmentID.init(uuidString:))
            holder = RepoID(uuidString: holderID).map {
                .place(.scope(repositoryID: $0, scope: environmentID.map(ConfigScope.environment) ?? .repository))
            }
        case "folder":
            holder = FolderID(uuidString: holderID).map { .place(.folder($0)) }
        case "destination":
            holder = DestinationID(uuidString: holderID).map { .place(.destination($0)) }
        case "organization":
            holder = OrganizationID(uuidString: holderID).map { .organization($0) }
        default:
            holder = nil
        }
        return holder.map { ItemNameMatchModel(id: id, kind: kind, name: name, holder: $0) }
    }
}
