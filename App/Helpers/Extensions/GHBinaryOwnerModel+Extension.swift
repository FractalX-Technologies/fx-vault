import GitHubKit

nonisolated extension GHBinaryOwnerModel {
    /// The owner's account name, or "with ID 502" when the user database has none (read as
    /// "the user with ID 502").
    var displayName: String {
        name ?? String(localized: "gh.owner.unnamed", defaultValue: "with ID \(uid)")
    }
}
