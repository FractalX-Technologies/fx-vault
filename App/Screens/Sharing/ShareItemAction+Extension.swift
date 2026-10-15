import SharingKit

/// What the user can choose per incoming item (§9.5). Values are never shown, only the choice.
extension ShareItemAction {
    var localizedTitle: String {
        switch self {
        case .add: String(localized: "share.action.add", defaultValue: "Add")
        case .addWithoutValue: String(localized: "share.action.addWithoutValue", defaultValue: "Add without value")
        case .fill: String(localized: "share.action.fill", defaultValue: "Fill value")
        case .skip: String(localized: "share.action.skip", defaultValue: "Skip")
        case .keepMine: String(localized: "share.action.keepMine", defaultValue: "Keep mine")
        case .overwrite: String(localized: "share.action.overwrite", defaultValue: "Overwrite")
        }
    }
}
