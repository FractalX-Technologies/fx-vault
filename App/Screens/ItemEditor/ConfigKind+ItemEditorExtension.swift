import VaultCore

extension ConfigKind {
    /// "Secret" or "Variable" (kind pickers of the editor sheets).
    var editorTitle: String {
        switch self {
        case .secret: String(localized: "itemEditor.kind.secret", defaultValue: "Secret")
        case .variable: String(localized: "itemEditor.kind.variable", defaultValue: "Variable")
        }
    }

    /// The other kind (Convert).
    var editorOpposite: ConfigKind {
        switch self {
        case .secret: .variable
        case .variable: .secret
        }
    }
}
