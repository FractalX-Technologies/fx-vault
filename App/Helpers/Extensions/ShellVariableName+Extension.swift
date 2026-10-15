import Foundation
import GitHubKit

nonisolated extension Array where Element == ShellVariableName {
    /// "GH_TOKEN" or "GH_TOKEN and GITHUB_TOKEN" (the variable names stay as written).
    var localizedList: String {
        ListFormatter.localizedString(byJoining: map(\.rawValue))
    }
}
