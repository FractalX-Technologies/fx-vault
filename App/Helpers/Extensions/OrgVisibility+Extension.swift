import Foundation
import VaultCore

extension OrgVisibility {
    /// The editor's Access segments: "All", "Private", "Selected".
    var accessTitle: String {
        switch self {
        case .all: String(localized: "organization.access.all", defaultValue: "All")
        case .private: String(localized: "organization.access.private", defaultValue: "Private")
        case .selected: String(localized: "organization.access.selected", defaultValue: "Selected")
        }
    }

    /// What an item reaches, short, as the boards' rows (Org-UsedBy, Main2-Repository): "all
    /// repos", "private and internal", "selected · 3 repos".
    func reachTitle(selectedCount: Int?) -> String {
        switch self {
        case .all:
            String(localized: "organization.reach.all", defaultValue: "all repos")
        case .private:
            String(localized: "organization.reach.private", defaultValue: "private and internal")
        case .selected:
            if let selectedCount {
                String(inflected: AttributedString(
                    localized: "organization.reach.selectedCount",
                    defaultValue: "selected · ^[\(selectedCount) repo](inflect: true)"
                ))
            } else {
                String(localized: "organization.reach.selected", defaultValue: "selected")
            }
        }
    }

    /// The editor's sentence under Access (mockup Org-Visibility): "All repositories", "Private
    /// and internal repositories" or "Selected · 3 repositories".
    func title(selectedCount: Int?) -> String {
        switch self {
        case .all:
            String(localized: "organization.visibility.all", defaultValue: "All repositories")
        case .private:
            String(localized: "organization.visibility.private", defaultValue: "Private and internal repositories")
        case .selected:
            if let selectedCount {
                String(localized: "organization.visibility.selectedCount", defaultValue: "Selected · \(selectedCount) repositories")
            } else {
                String(localized: "organization.visibility.selected", defaultValue: "Selected repositories")
            }
        }
    }
}
