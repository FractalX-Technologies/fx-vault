import Foundation
import VaultCore

/// Reads the notes editor's paragraphs as `KEY = value` lines (1.0 N2; boards Place-Edit,
/// Place-Errors, KV-NameRules): each line's mark and note, and the save it would make. A line
/// keeps its item through its token or the variable characters it still holds; one problem per
/// line, the first of kind, name, value and a name used twice.
enum NotesEditAnalysis {
    /// The character that stands for a token in the text (`NSTextAttachment.character`).
    static let tokenCharacter = "\u{FFFC}"

    /// A `KEY = value` line before its problems are known.
    private struct Item {
        let index: Int
        let kind: ConfigKind
        let typedName: String
        let nameRange: NSRange
        let name: String
        let value: Value
        let origin: NotesEditOriginModel?
        var problem: Problem?
    }

    private enum Value {
        case missingEquals
        case mixed
        case some(NotesEditValueModel)
    }

    private struct Problem {
        let text: String
        var isName = false
    }

    private struct NameKey: Hashable {
        let kind: ConfigKind
        let key: String
    }

    static func analyze(
        paragraphs: [NotesParagraphModel],
        origins: [NotesEditOriginModel],
        tokens: [NotesTokenID: NotesTokenModel],
        place: NotesEditPlaceKind
    ) -> NotesEditAnalysisModel {
        let originsByID = Dictionary(origins.map { ($0.id, $0) }) { first, _ in first }
        var claimed: Set<ConfigItemID> = []
        var lines: [NotesEditLineModel] = []
        var items: [Item] = []
        var section = place.kinds.first ?? .secret

        for (index, paragraph) in paragraphs.enumerated() {
            if let heading = paragraph.heading {
                section = heading
                lines.append(NotesEditLineModel(role: .heading(heading)))
                continue
            }
            let trimmed = paragraph.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.append(NotesEditLineModel(role: .blank))
                continue
            }
            if trimmed.hasPrefix("#") {
                lines.append(NotesEditLineModel(role: .comment, note: .info(NotesEditCopy.commentNotSaved)))
                continue
            }
            lines.append(NotesEditLineModel(role: .item))
            let item = parse(paragraph, index: index, kind: section, place: place, tokens: tokens) { candidate in
                guard let candidate, !claimed.contains(candidate), let origin = originsByID[candidate] else { return nil }
                claimed.insert(candidate)
                return origin
            }
            items.append(item)
        }

        for index in items.indices where items[index].problem == nil {
            items[index].problem = problem(of: items[index], tokens: tokens, place: place)
        }
        markDuplicates(&items, place: place)

        var plan = NotesEditPlanModel()
        for item in items {
            lines[item.index] = line(for: item, tokens: tokens, place: place, plan: &plan)
        }
        plan.removals = origins.filter { !claimed.contains($0.id) }
        return NotesEditAnalysisModel(lines: lines, plan: plan)
    }

    // MARK: - Parsing

    /// Splits `KEY = value` at the first `=`; one space after it is the separator, not the value.
    private static func parse(
        _ paragraph: NotesParagraphModel,
        index: Int,
        kind: ConfigKind,
        place: NotesEditPlaceKind,
        tokens: [NotesTokenID: NotesTokenModel],
        claim: (ConfigItemID?) -> NotesEditOriginModel?
    ) -> Item {
        let text = paragraph.text as NSString
        let equals = text.range(of: "=")
        let nameEnd = equals.location == NSNotFound ? text.length : equals.location
        let nameRange = trimmedRange(in: text, upTo: nameEnd)
        let typedName = text.substring(with: nameRange)
        let tokensInName = typedName.components(separatedBy: tokenCharacter).count - 1

        var value = Value.missingEquals
        if equals.location != NSNotFound {
            var rest = text.substring(from: equals.location + 1)
            if rest.hasPrefix(" ") {
                rest.removeFirst()
            }
            value = parseValue(rest, tokens: Array(paragraph.tokens.dropFirst(tokensInName)))
        }

        var origin: NotesEditOriginModel?
        if case .some(.token(let id)) = value, let tokenOrigin = tokens[id]?.origin {
            origin = claim(tokenOrigin)
        }
        if origin == nil {
            origin = claim(paragraph.itemID)
        }
        return Item(
            index: index,
            kind: kind,
            typedName: typedName,
            nameRange: nameRange,
            name: place.normalizedName(typedName),
            value: value,
            origin: origin
        )
    }

    private static func parseValue(_ rest: String, tokens: [NotesTokenID]) -> Value {
        let parts = rest.components(separatedBy: tokenCharacter)
        switch parts.count {
        case 1:
            return .some(.text(rest))
        case 2 where parts.allSatisfy({ $0.allSatisfy(\.isWhitespace) }):
            return tokens.first.map { .some(.token($0)) } ?? .mixed
        default:
            return .mixed
        }
    }

    /// The range of `text[..<end]` without its leading and trailing spaces and tabs.
    private static func trimmedRange(in text: NSString, upTo end: Int) -> NSRange {
        var start = 0
        var stop = end
        while start < stop, isBlank(text.character(at: start)) {
            start += 1
        }
        while stop > start, isBlank(text.character(at: stop - 1)) {
            stop -= 1
        }
        return NSRange(location: start, length: stop - start)
    }

    private static func isBlank(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    // MARK: - Problems

    private static func problem(of item: Item, tokens: [NotesTokenID: NotesTokenModel], place: NotesEditPlaceKind) -> Problem? {
        if let kindProblem = kindProblem(of: item, tokens: tokens) {
            return Problem(text: kindProblem)
        }
        if item.typedName.isEmpty {
            return Problem(text: NotesEditCopy.addName)
        }
        if let nameProblem = place.nameProblem(item.typedName) {
            return Problem(text: nameProblem, isName: true)
        }
        return valueProblem(of: item, tokens: tokens, place: place).map { Problem(text: $0) }
    }

    /// A line in the other kind's section than its item or token was made for (board Place-Errors).
    private static func kindProblem(of item: Item, tokens: [NotesTokenID: NotesTokenModel]) -> String? {
        var madeFor = item.origin?.kind
        if case .some(.token(let id)) = item.value, let token = tokens[id] {
            madeFor = token.kind
        }
        guard let madeFor, madeFor != item.kind else { return nil }
        if item.origin?.isSynced == true {
            return NotesEditCopy.kindFixed
        }
        return NotesEditCopy.belongs(in: madeFor)
    }

    private static func valueProblem(of item: Item, tokens: [NotesTokenID: NotesTokenModel], place: NotesEditPlaceKind) -> String? {
        switch item.value {
        case .missingEquals:
            return NotesEditCopy.addEquals
        case .mixed:
            return NotesEditCopy.oneValue
        case .some(.text(let text)):
            let isEmpty = text.allSatisfy(\.isWhitespace)
            if item.kind == .secret {
                return isEmpty ? NotesEditCopy.setValue : NotesEditCopy.secretValueInText
            }
            return isEmpty ? NotesEditCopy.addValue : place.sizeProblem(byteCount: text.utf8.count)
        case .some(.token(let id)):
            guard let token = tokens[id] else { return NotesEditCopy.oneValue }
            if !token.hasValue {
                // An existing secret without a value stays as it is ("no value").
                return item.origin == nil ? NotesEditCopy.setValue : nil
            }
            return token.newValueBytes.flatMap { place.sizeProblem(byteCount: $0) }
        }
    }

    /// Names that would be one item: each line but the one that keeps it gets the problem. The
    /// keeper is the existing item that kept its name, else the first line.
    private static func markDuplicates(_ items: inout [Item], place: NotesEditPlaceKind) {
        var groups: [NameKey: [Int]] = [:]
        for (position, item) in items.enumerated() where item.problem == nil {
            groups[NameKey(kind: item.kind, key: GitHubNameValidator.foldKey(item.name)), default: []].append(position)
        }
        for positions in groups.values where positions.count > 1 {
            let owner = positions.first { items[$0].origin?.name == items[$0].name }
            let keeper = owner ?? positions[0]
            for position in positions where position != keeper {
                let remote = place.remoteName(items[keeper].name)
                let text = switch (remote, owner) {
                case (let remote?, .some): NotesEditCopy.sameInKeyVault(remote)
                case (let remote?, nil): NotesEditCopy.bothBecome(remote)
                case (nil, _): NotesEditCopy.sameNameAsLine(items[keeper].index + 1)
                }
                items[position].problem = Problem(text: text, isName: true)
            }
        }
    }

    // MARK: - Notes and the plan

    private static func line(
        for item: Item,
        tokens: [NotesTokenID: NotesTokenModel],
        place: NotesEditPlaceKind,
        plan: inout NotesEditPlanModel
    ) -> NotesEditLineModel {
        // A new line's name, or a kept item's when it changed.
        let newName: String? = if let origin = item.origin { origin.name == item.name ? nil : item.name } else { item.name }
        let newValue = changedValue(of: item, tokens: tokens)
        let isEdited = item.origin == nil || newName != nil || newValue != nil
        var line = NotesEditLineModel(role: .item, mark: isEdited ? .pending : item.origin?.mark)
        if let problem = item.problem {
            line.note = .error(problem.text)
            line.nameErrorRange = problem.isName ? item.nameRange : nil
            return line
        }
        guard case .some(let value) = item.value else { return line }
        let savedAs = savedAsNote(for: item, place: place)
        guard let origin = item.origin else {
            plan.additions.append(.init(kind: item.kind, name: item.name, value: value))
            line.note = .info(savedAs ?? NotesEditCopy.new(item.kind))
            return line
        }
        guard isEdited else {
            line.note = origin.note.map(NotesEditNoteModel.info)
            return line
        }
        plan.changes.append(.init(origin: origin, name: newName, value: newValue))
        let valueNote: String? = switch newValue {
        case .text?: origin.text.map { NotesEditCopy.was(NotesEditCopy.shortened($0, maxLength: wasLength)) }
        case .token?: origin.kind == .secret && origin.hasValue ? NotesEditCopy.replacesValue : NotesEditCopy.valueSet
        case nil: nil
        }
        let renamedNote = newName.map { _ in NotesEditCopy.renamed(from: origin.name) }
        line.note = .info(PlaceCopy.subline([renamedNote, valueNote, newName == nil ? nil : savedAs]))
        return line
    }

    /// The value a kept item gets, or nil when it keeps its own.
    private static func changedValue(of item: Item, tokens: [NotesTokenID: NotesTokenModel]) -> NotesEditValueModel? {
        guard let origin = item.origin, case .some(let value) = item.value else { return nil }
        switch value {
        case .text(let text):
            return text == origin.text ? nil : value
        case .token(let id):
            return tokens[id]?.newValueBytes == nil ? nil : value
        }
    }

    /// "saved as CACHE-URL" when the saved name is not the typed one (KV-NameRules).
    private static func savedAsNote(for item: Item, place: NotesEditPlaceKind) -> String? {
        let saved = place.remoteName(item.name) ?? item.name
        return saved == item.typedName ? nil : NotesEditCopy.savedAs(saved)
    }

    private static let wasLength = 24
}
