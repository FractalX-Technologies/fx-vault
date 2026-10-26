import Foundation
import Testing
import VaultCore
@testable import FXVault

/// The notes editor's text read as lines (1.0 N2; boards Place-Edit, Place-Errors, KV-NameRules):
/// what each line keeps, adds or removes, its note, and why a line can't be saved.
@MainActor
@Suite("Notes editing: analysis")
struct NotesEditAnalysisTests {
    /// The editor's paragraphs, built line by line.
    @MainActor
    struct Draft {
        var paragraphs: [NotesParagraphModel] = []
        var tokens: [NotesTokenID: NotesTokenModel] = [:]

        mutating func heading(_ kind: ConfigKind) {
            paragraphs.append(NotesParagraphModel(text: "# \(kind)", heading: kind))
        }

        mutating func line(_ text: String, item: ConfigItemID? = nil) {
            paragraphs.append(NotesParagraphModel(text: text, itemID: item))
        }

        /// `NAME = ` and a token.
        @discardableResult
        mutating func token(
            _ name: String,
            kind: ConfigKind = .secret,
            origin: ConfigItemID? = nil,
            hasValue: Bool = true,
            newValueBytes: Int? = nil
        ) -> NotesTokenID {
            let token = NotesTokenModel(id: NotesTokenID(), kind: kind, origin: origin, hasValue: hasValue, newValueBytes: newValueBytes)
            tokens[token.id] = token
            paragraphs.append(NotesParagraphModel(text: "\(name) = \(NotesEditAnalysis.tokenCharacter)", tokens: [token.id]))
            return token.id
        }

        func analyze(_ origins: [NotesEditOriginModel], place: NotesEditPlaceKind = .repository) -> NotesEditAnalysisModel {
            NotesEditAnalysis.analyze(paragraphs: paragraphs, origins: origins, tokens: tokens, place: place)
        }
    }

    static func origin(
        _ name: String,
        _ kind: ConfigKind = .secret,
        text: String? = nil,
        isSynced: Bool = true,
        hasValue: Bool = true,
        note: String? = nil
    ) -> NotesEditOriginModel {
        NotesEditOriginModel(
            id: ConfigItemID(),
            name: name,
            kind: kind,
            isSynced: isSynced,
            hasValue: hasValue,
            variableValue: text,
            mark: nil,
            note: note,
            overrides: nil
        )
    }

    private func notes(_ analysis: NotesEditAnalysisModel) -> [String?] {
        analysis.lines.map { $0.note?.text }
    }

    // MARK: - Kept, added, changed, removed

    @Test func keptLinesChangeNothing() {
        let secret = Self.origin("API_KEY", note: "overrides example-org")
        let variable = Self.origin("LOG_LEVEL", .variable, text: "info")
        var draft = Draft()
        draft.heading(.secret)
        draft.token("API_KEY", origin: secret.id)
        draft.line("")
        draft.heading(.variable)
        draft.line("LOG_LEVEL = info", item: variable.id)

        let analysis = draft.analyze([secret, variable])

        #expect(analysis.plan.count == 0)
        #expect(analysis.errorCount == 0)
        #expect(notes(analysis) == [nil, "overrides example-org", nil, nil, nil])
        #expect(analysis.lines.allSatisfy { $0.mark == nil })
    }

    @Test func editsBecomeAddedChangedAndRemoved() {
        let secret = Self.origin("API_KEY")
        let removed = Self.origin("STRIPE_KEY")
        let variable = Self.origin("LOG_LEVEL", .variable, text: "info")
        var draft = Draft()
        draft.heading(.secret)
        let replaced = draft.token("API_KEY", origin: secret.id, newValueBytes: 12)
        let added = draft.token("NEW_API_KEY", newValueBytes: 8)
        draft.heading(.variable)
        draft.line("LOG_LEVEL = debug", item: variable.id)
        draft.line("FEATURE_FLAGS = beta,search")

        let analysis = draft.analyze([secret, removed, variable])

        #expect(analysis.plan.additions == [
            .init(kind: .secret, name: "NEW_API_KEY", value: .token(added)),
            .init(kind: .variable, name: "FEATURE_FLAGS", value: .text("beta,search")),
        ])
        #expect(analysis.plan.changes == [
            .init(origin: secret, name: nil, value: .token(replaced)),
            .init(origin: variable, name: nil, value: .text("debug")),
        ])
        #expect(analysis.plan.removals == [removed])
        #expect(notes(analysis) == [nil, NotesEditCopy.replacesValue, NotesEditCopy.new(.secret), nil, NotesEditCopy.was("info"), NotesEditCopy.new(.variable)])
        #expect(analysis.lines.map(\.mark) == [nil, .pending, .pending, nil, .pending, .pending])
    }

    @Test func aRenamedLineKeepsItsItem() {
        let secret = Self.origin("API_KEY")
        let variable = Self.origin("LOG_LEVEL", .variable, text: "info")
        var draft = Draft()
        draft.heading(.secret)
        draft.token("API_TOKEN", origin: secret.id)
        draft.heading(.variable)
        draft.line("LOG_LVL = info", item: variable.id)

        let analysis = draft.analyze([secret, variable])

        #expect(analysis.plan.changes == [
            .init(origin: secret, name: "API_TOKEN", value: nil),
            .init(origin: variable, name: "LOG_LVL", value: nil),
        ])
        #expect(analysis.plan.removals.isEmpty)
        #expect(notes(analysis)[1] == NotesEditCopy.renamed(from: "API_KEY"))
    }

    /// A copied line holds the same item's characters: the first line keeps the item.
    @Test func anItemIsKeptByOneLineOnly() {
        let variable = Self.origin("LOG_LEVEL", .variable, text: "info")
        var draft = Draft()
        draft.heading(.variable)
        draft.line("LOG_LEVEL = info", item: variable.id)
        draft.line("LOG_LEVEL_COPY = info", item: variable.id)

        let analysis = draft.analyze([variable])

        #expect(analysis.plan.changes.isEmpty)
        #expect(analysis.plan.additions == [.init(kind: .variable, name: "LOG_LEVEL_COPY", value: .text("info"))])
    }

    @Test func namesAreSavedInCapitals() {
        var draft = Draft()
        draft.heading(.variable)
        draft.line("log_level = debug")

        let analysis = draft.analyze([])

        #expect(analysis.plan.additions == [.init(kind: .variable, name: "LOG_LEVEL", value: .text("debug"))])
        #expect(notes(analysis)[1] == NotesEditCopy.savedAs("LOG_LEVEL"))
    }

    @Test func commentsStayOutOfTheSave() {
        var draft = Draft()
        draft.heading(.variable)
        draft.line("# rotate in May")

        let analysis = draft.analyze([])

        #expect(analysis.plan.count == 0)
        #expect(analysis.lines[1].role == .comment)
        #expect(notes(analysis)[1] == NotesEditCopy.commentNotSaved)
    }

    // MARK: - Lines that can't be saved (board Place-Errors)

    @Test func namesFollowGitHubsRules() {
        var draft = Draft()
        draft.heading(.secret)
        draft.token("GITHUB_TOKEN", newValueBytes: 4)
        draft.heading(.variable)
        draft.line("MY-KEY = x")
        draft.line("1KEY = x")

        let analysis = draft.analyze([])

        #expect(notes(analysis) == [nil, NotesEditCopy.reservedPrefix, nil, NotesEditCopy.lettersDigits, NotesEditCopy.leadingDigit])
        #expect(analysis.lines[1].nameErrorRange == NSRange(location: 0, length: 12))
        #expect(analysis.lines[3].nameErrorRange == NSRange(location: 0, length: 6))
        #expect(analysis.errorCount == 3)
        #expect(analysis.plan.additions.isEmpty)
    }

    @Test func valuesOverTheLimitAreErrors() {
        var draft = Draft()
        draft.heading(.secret)
        draft.token("CERT_BUNDLE", newValueBytes: 65_536)
        draft.heading(.variable)
        draft.line("BIG = \(String(repeating: "x", count: Limits.maxValueBytes + 1))")

        let analysis = draft.analyze([])

        #expect(notes(analysis)[1] == NotesEditCopy.tooLarge(bytes: 65_536, limit: Limits.maxValueBytes, isKeyVault: false))
        #expect(notes(analysis)[3] == NotesEditCopy.tooLarge(bytes: Limits.maxValueBytes + 1, limit: Limits.maxValueBytes, isKeyVault: false))
        #expect(analysis.lines[1].nameErrorRange == nil)
    }

    @Test func aLineKeepsItsKindAcrossSections() {
        let synced = Self.origin("JWT_SECRET")
        let unsynced = Self.origin("DRAFT_KEY", isSynced: false)
        let variable = Self.origin("LOG_LEVEL", .variable, text: "info")
        var draft = Draft()
        draft.heading(.secret)
        draft.line("LOG_LEVEL = info", item: variable.id)
        draft.heading(.variable)
        draft.token("JWT_SECRET", origin: synced.id)
        draft.token("DRAFT_KEY", origin: unsynced.id)
        draft.token("NEW_KEY", newValueBytes: 3)

        let analysis = draft.analyze([synced, unsynced, variable])

        #expect(notes(analysis) == [
            nil, NotesEditCopy.kindFixed, nil, NotesEditCopy.kindFixed, NotesEditCopy.belongs(in: .secret), NotesEditCopy.belongs(in: .secret),
        ])
        // Still their items: nothing reads as removed.
        #expect(analysis.plan.removals.isEmpty)
    }

    @Test func aNewSecretNeedsAValueAnExistingOneKeepsItsOwn() {
        let missing = Self.origin("SENTRY_DSN", hasValue: false, note: NotesCopy.noValue)
        var draft = Draft()
        draft.heading(.secret)
        draft.token("SENTRY_DSN", origin: missing.id, hasValue: false)
        draft.token("NEW_API_KEY", hasValue: false)

        let analysis = draft.analyze([missing])

        #expect(notes(analysis) == [nil, NotesCopy.noValue, NotesEditCopy.setValue])
        #expect(analysis.errorCount == 1)
    }

    @Test func incompleteLinesAreErrors() {
        var draft = Draft()
        draft.heading(.secret)
        draft.line("NEW_KEY")
        draft.line("TYPED = plain text")
        draft.heading(.variable)
        draft.line("= value")
        draft.line("EMPTY = ")

        let analysis = draft.analyze([])

        #expect(notes(analysis) == [
            nil, NotesEditCopy.addEquals, NotesEditCopy.secretValueInText, nil, NotesEditCopy.addName, NotesEditCopy.addValue,
        ])
    }

    @Test func aNameUsedTwiceIsAnError() {
        let variable = Self.origin("LOG_LEVEL", .variable, text: "info")
        var draft = Draft()
        draft.heading(.secret)
        draft.token("LOG_LEVEL", newValueBytes: 2)
        draft.heading(.variable)
        draft.line("log_level = debug")
        draft.line("LOG_LEVEL = info", item: variable.id)

        let analysis = draft.analyze([variable])

        // A secret and a variable may share a name; the existing variable keeps its own.
        #expect(notes(analysis) == [nil, NotesEditCopy.new(.secret), nil, NotesEditCopy.sameNameAsLine(5), nil])
        #expect(analysis.lines[3].nameErrorRange == NSRange(location: 0, length: 9))
    }

    // MARK: - Key Vault (board KV-NameRules)

    @Test func keyVaultNamesCompareAsKeyVaultStoresThem() {
        let stripe = Self.origin("STRIPE_KEY")
        var draft = Draft()
        draft.heading(.secret)
        draft.token("STRIPE_KEY", origin: stripe.id)
        draft.token("stripe-key", newValueBytes: 3)
        draft.token("CACHE_URL", newValueBytes: 3)
        draft.token("cache-url", newValueBytes: 3)
        draft.token(String(repeating: "A", count: DestinationRules.maxKeyVaultNameLength + 1), newValueBytes: 3)
        draft.token("CERT", newValueBytes: Limits.maxKeyVaultValueBytes + 1)

        let analysis = draft.analyze([stripe], place: .keyVault)

        #expect(notes(analysis) == [
            nil,
            nil,
            NotesEditCopy.sameInKeyVault("STRIPE-KEY"),
            NotesEditCopy.savedAs("CACHE-URL"),
            NotesEditCopy.bothBecome("CACHE-URL"),
            NotesEditCopy.keyVaultTooLong(DestinationRules.maxKeyVaultNameLength),
            NotesEditCopy.tooLarge(bytes: Limits.maxKeyVaultValueBytes + 1, limit: Limits.maxKeyVaultValueBytes, isKeyVault: true),
        ])
        #expect(analysis.errorCount == 4)
    }
}
