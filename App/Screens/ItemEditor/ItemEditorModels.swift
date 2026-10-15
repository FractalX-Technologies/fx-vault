import VaultCore

/// A scope an item can move to (Convert/Move, D11).
struct ItemScopeOptionModel: Identifiable, Hashable {
    let scope: ConfigScope
    let title: String
    /// False where the viewer cannot change items (environments need admin, §2 Permissions).
    let isEditable: Bool

    var id: String {
        scope.environmentID?.uuidString ?? ConfigScopeLevel.repository.rawValue
    }
}

/// A confirmation the editor asks before a risky save (secret → variable, §5.13). The confirm
/// button is destructive, so Cancel is the default (Return) button.
struct ItemEditorConfirmationModel: Hashable {
    let title: String
    let message: String
    let confirmTitle: String
}

/// The credential-looking-variable warning (§5.13): the reasons, never the value, plus what the
/// editor can do about it.
struct CredentialWarningModel: Hashable {
    enum Action: Hashable {
        /// The kind can still change: switch the picker to Secret.
        case switchToSecret
        /// The variable is on GitHub (kind locked, D11): open Convert or Move.
        case convertToSecret
    }

    let reasons: [String]
    let action: Action?
}
