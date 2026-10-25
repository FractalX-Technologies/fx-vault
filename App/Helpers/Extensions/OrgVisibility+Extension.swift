import VaultCore

extension OrgVisibility {
    /// Who can use an organization item (mockup Org-Visibility): "All repositories", "Private
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
