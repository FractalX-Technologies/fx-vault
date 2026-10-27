import Foundation

/// A chooser's search text, trimmed: empty matches everything, otherwise a candidate matches
/// when it contains the text in any case.
struct SearchQuery {
    /// A chooser shows its search field once it lists more than this many rows.
    static let fieldThreshold = 1

    let text: String

    init(_ raw: String) {
        text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool {
        text.isEmpty
    }

    func matches(_ candidates: String...) -> Bool {
        isEmpty || candidates.contains { $0.localizedCaseInsensitiveContains(text) }
    }
}
