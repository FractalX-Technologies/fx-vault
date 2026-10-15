import Foundation

/// The phrases of the §7.2 summary. The app supplies them from its string catalog (packages
/// ship no user-facing text, D24); tests supply an English set.
public struct ChangeSummaryVocabulary: Sendable {
    /// Header detail of a repository that will be created, e.g.
    /// `(new repository · private · README · Swift .gitignore · MIT)`.
    public var newRepository: @Sendable (NewRepositorySummaryModel) -> String
    /// Scope label, e.g. `Repository`, `production`, `staging → stage`.
    public var scopeLabel: @Sendable (ScopeChangeSummaryModel) -> String
    /// Status column, e.g. `2 added, 1 modified` or `renamed (recreated on GitHub)`.
    public var scopeStatus: @Sendable (ScopeChangeSummaryModel) -> String
    /// One item detail, e.g. `+ SENTRY_DSN (secret)`.
    public var item: @Sendable (ItemChangeSummaryModel) -> String
    /// Policy detail, e.g. `policy: custom (release/*)`.
    public var policy: @Sendable (PolicySummaryModel) -> String
    /// One blocked line, e.g. `Blocked: DB_PASSWORD in production — value missing locally`.
    public var blocked: @Sendable (BlockedSummaryModel) -> String
    /// The remote-changed line of one repository (never called with an empty list).
    public var remoteChanged: @Sendable ([RemoteChangedSummaryModel]) -> String
    /// The write-limit line.
    public var writeBudget: @Sendable (WriteBudgetModel) -> String

    public init(
        newRepository: @escaping @Sendable (NewRepositorySummaryModel) -> String,
        scopeLabel: @escaping @Sendable (ScopeChangeSummaryModel) -> String,
        scopeStatus: @escaping @Sendable (ScopeChangeSummaryModel) -> String,
        item: @escaping @Sendable (ItemChangeSummaryModel) -> String,
        policy: @escaping @Sendable (PolicySummaryModel) -> String,
        blocked: @escaping @Sendable (BlockedSummaryModel) -> String,
        remoteChanged: @escaping @Sendable ([RemoteChangedSummaryModel]) -> String,
        writeBudget: @escaping @Sendable (WriteBudgetModel) -> String
    ) {
        self.newRepository = newRepository
        self.scopeLabel = scopeLabel
        self.scopeStatus = scopeStatus
        self.item = item
        self.policy = policy
        self.blocked = blocked
        self.remoteChanged = remoteChanged
        self.writeBudget = writeBudget
    }
}

/// Lays out a ``ChangeSummaryModel`` as the plain-text block of §7.2 (for the copyable
/// summary and the last-run report). Layout only; every phrase comes from the vocabulary.
///
/// ```
/// owner-a/api   (new repository · private · README · MIT)
///   Repository   2 added, 1 modified   + SENTRY_DSN (secret)  ~ STRIPE_KEY (secret)
///   qa           deleted — contents fetched live at confirmation
/// Blocked: DB_PASSWORD in production — value missing locally
/// ```
///
/// Columns are padded in characters (monospaced display): the label column to the longest
/// label, the status column to the longest status of a line that has details, each followed
/// by ``columnGap`` spaces. The header detail starts at the details column when the name fits.
public enum ChangeSummaryRenderer {
    /// Spaces between columns.
    public static let columnGap = 3
    /// Indentation of scope lines.
    public static let scopeIndent = 2
    /// Spaces between details on one line.
    public static let detailGap = 2

    /// The summary as lines (no trailing newline characters).
    public static func lines(_ summary: ChangeSummaryModel, vocabulary: ChangeSummaryVocabulary) -> [String] {
        var lines: [String] = []
        for repository in summary.repositories {
            lines += self.lines(repository, vocabulary: vocabulary)
        }
        if let budget = summary.writeBudget {
            lines.append(vocabulary.writeBudget(budget))
        }
        return lines
    }

    /// The summary as one newline-separated string.
    public static func render(_ summary: ChangeSummaryModel, vocabulary: ChangeSummaryVocabulary) -> String {
        lines(summary, vocabulary: vocabulary).joined(separator: "\n")
    }

    private static func lines(_ repository: RepoChangeSummaryModel, vocabulary: ChangeSummaryVocabulary) -> [String] {
        let rows = repository.scopes.map { scope in
            ScopeRow(
                label: vocabulary.scopeLabel(scope),
                status: vocabulary.scopeStatus(scope),
                details: (scope.policy.map { [vocabulary.policy($0)] } ?? []) + scope.items.map(vocabulary.item)
            )
        }
        let labelWidth = (rows.map(\.label.count).max() ?? 0) + columnGap
        let statusWidth = (rows.filter { !$0.details.isEmpty }.map(\.status.count).max() ?? 0) + columnGap
        let gap = String(repeating: " ", count: detailGap)

        var lines: [String] = []
        if let newRepository = repository.newRepository {
            let detailsColumn = scopeIndent + labelWidth + statusWidth
            let width = max(repository.fullName.count + columnGap, detailsColumn)
            lines.append(padded(repository.fullName, to: width) + vocabulary.newRepository(newRepository))
        } else {
            lines.append(repository.fullName)
        }
        let indent = String(repeating: " ", count: scopeIndent)
        for row in rows {
            var line = indent + padded(row.label, to: labelWidth)
            if row.details.isEmpty {
                line += row.status
            } else {
                line += padded(row.status, to: statusWidth) + row.details.joined(separator: gap)
            }
            lines.append(line)
        }
        lines += repository.blocked.map(vocabulary.blocked)
        if !repository.remoteChanged.isEmpty {
            lines.append(vocabulary.remoteChanged(repository.remoteChanged))
        }
        return lines
    }

    private static func padded(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(width - text.count, 0))
    }

    private struct ScopeRow {
        var label: String
        var status: String
        var details: [String]
    }
}
