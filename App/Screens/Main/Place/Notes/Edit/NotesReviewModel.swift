import Foundation
import VaultCore

/// "Review changes to production" (board Place-Review): names, kinds and variable values only;
/// a secret's value is "value set".
struct NotesReviewModel: Identifiable, Hashable {
    struct Row: Identifiable, Hashable {
        let id: String
        let name: String
        let kind: ConfigKind
        let detail: String?
    }

    struct Section: Identifiable, Hashable {
        let id: String
        let title: String
        let rows: [Row]
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let sections: [Section]
    let footer: String

    private static let detailLength = 40

    init(session: NotesEditSession) {
        let plan = session.analysis.plan
        let target = session.target
        title = NotesEditCopy.reviewTitle(target.title)
        subtitle = PlaceCopy.subline([target.parent, NotesEditCopy.changeCount(plan.count)])
        footer = switch target.kind {
        case .repository: NotesEditCopy.footerGitHub
        case .folder: NotesEditCopy.footerFolder
        case .keyVault: NotesEditCopy.footerKeyVault
        }
        let added = plan.additions.map { addition in
            Row(
                id: "\(addition.kind)|\(addition.name)",
                name: addition.name,
                kind: addition.kind,
                detail: Self.detail(of: addition.value, kind: addition.kind, session: session)
            )
        }
        let changed = plan.changes.map { change in
            let renamed = change.name.map { _ in NotesEditCopy.renamed(from: change.origin.name) }
            let value: String? = switch change.value {
            case .text(let text)?: NotesEditCopy.valueChange(from: Self.short(change.origin.text ?? ""), to: Self.short(text))
            case let value?: Self.detail(of: value, kind: change.origin.kind, session: session)
            case nil: nil
            }
            return Row(
                id: change.origin.id.uuidString,
                name: change.name ?? change.origin.name,
                kind: change.origin.kind,
                detail: PlaceCopy.subline([renamed, value])
            )
        }
        let removed = plan.removals.map { origin in
            Row(
                id: origin.id.uuidString,
                name: origin.name,
                kind: origin.kind,
                detail: origin.overrides.map(NotesEditCopy.organizationValueApplies)
            )
        }
        sections = [
            Section(id: "added", title: NotesEditCopy.added(added.count), rows: added),
            Section(id: "changed", title: NotesEditCopy.changed(changed.count), rows: changed),
            Section(id: "removed", title: NotesEditCopy.removed(removed.count), rows: removed),
        ].filter { !$0.rows.isEmpty }
    }

    /// A variable's text, "value set" for a secret, "3 lines" for a variable held as a token.
    private static func detail(of value: NotesEditValueModel, kind: ConfigKind, session: NotesEditSession) -> String {
        switch value {
        case .text(let text):
            return short(text)
        case .token(let id):
            guard kind == .variable, case .lines(let count) = session.display(of: id) else { return NotesEditCopy.valueSet }
            return NotesEditCopy.lines(count)
        }
    }

    private static func short(_ text: String) -> String {
        NotesEditCopy.shortened(text, maxLength: detailLength)
    }
}
