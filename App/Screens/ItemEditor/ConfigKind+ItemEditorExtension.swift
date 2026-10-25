import VaultCore

extension ConfigKind {
    /// "Secret" or "Variable" (kind pickers of the editor sheets).
    var editorTitle: String {
        switch self {
        case .secret: String(localized: "itemEditor.kind.secret", defaultValue: "Secret")
        case .variable: String(localized: "itemEditor.kind.variable", defaultValue: "Variable")
        }
    }

    /// "Add Secret" or "Add Variable" (the detail columns' add buttons).
    var addTitle: String {
        switch self {
        case .secret: String(localized: "main.detail.addSecret", defaultValue: "Add Secret")
        case .variable: String(localized: "main.detail.addVariable", defaultValue: "Add Variable")
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
