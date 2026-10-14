/// Errors from the local database layer (tasks/todo.md §4.4).
///
/// GRDB is imported only in VaultStore (D2, §4.2), so callers cannot inspect GRDB's
/// `DatabaseError`. Every store method translates database failures into these cases. No case
/// carries SQL, a statement argument or SQLite's message text, so an error can be logged without
/// leaking names or blobs.
public enum StoreError: Error, Sendable, Hashable {
    /// The row the operation targets does not exist.
    case notFound
    /// A schema constraint rejected the write (§6).
    case constraintViolation(StoreConstraint)
    /// A config item or branch pattern points at an environment of another repository.
    case scopeMismatch
    /// The write would change a config item's kind or scope after it was synced (D11).
    case immutableAfterSync
    /// The database was migrated by a newer build of FX Vault; this build must not open it.
    case schemaNewerThanBuild
    /// The vault directory could not be created with mode 0700, or is not a plain directory
    /// (§6 Storage, D10).
    case insecureDirectory
    /// A stored value could not be decoded into its Swift type (tampered or corrupt row).
    case invalidStoredValue
    /// SQLite stayed busy or locked past the busy timeout.
    case busy
    /// The database file is not a valid SQLite database.
    case corruptDatabase
    /// Any other SQLite failure, identified by its extended result code.
    case database(code: Int32)
}

/// The kind of constraint that rejected a write (`StoreError.constraintViolation`).
public enum StoreConstraint: String, Sendable, Hashable, CaseIterable {
    /// A UNIQUE column or unique index (for example `environments_repo_name`).
    case unique
    /// A PRIMARY KEY.
    case primaryKey
    /// A CHECK constraint (enum columns, uppercase names, blob lengths, value pairing).
    case check
    /// A FOREIGN KEY.
    case foreignKey
    /// A NOT NULL column.
    case notNull
    /// Any other constraint.
    case other
}
