import VaultCore

/// A listed item's name with its kind. A converted item can leave a secret and a variable with
/// one name, so lists of names key their rows by both (Settings "Show names", the "Delete?" sheet).
struct ItemNameModel: Identifiable, Hashable {
    let kind: ConfigKind
    let name: String

    var id: Self {
        self
    }
}
