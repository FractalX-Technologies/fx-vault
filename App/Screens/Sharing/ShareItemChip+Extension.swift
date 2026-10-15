import SharingKit
import SwiftUI

/// The preview chips of a share import (§9.5): New / Fills missing value / Value not included /
/// Exists locally / Same / Differs, plus the two "skipped" notes.
extension ShareItemChip {
    var localizedTitle: String {
        switch self {
        case .new: String(localized: "share.chip.new", defaultValue: "New")
        case .fillsMissingValue: String(localized: "share.chip.fills", defaultValue: "Fills missing value")
        case .valueNotIncluded: String(localized: "share.chip.valueNotIncluded", defaultValue: "Value not included")
        case .existsLocally: String(localized: "share.chip.existsLocally", defaultValue: "Exists locally")
        case .same: String(localized: "share.chip.same", defaultValue: "Same")
        case .differs: String(localized: "share.chip.differs", defaultValue: "Differs")
        case .otherKindExists: String(localized: "share.chip.otherKind", defaultValue: "Exists as other kind")
        case .deletedLocally: String(localized: "share.chip.deletedLocally", defaultValue: "Deleted locally")
        }
    }

    var tint: Color {
        switch self {
        case .new, .fillsMissingValue: Theme.Colors.pending
        case .same: Theme.Colors.success
        case .differs, .otherKindExists, .valueNotIncluded: Theme.Colors.warning
        case .existsLocally: Theme.Colors.textSecondary
        case .deletedLocally: Theme.Colors.danger
        }
    }

    var chip: StatusChip {
        StatusChip(title: localizedTitle, tint: tint)
    }
}
