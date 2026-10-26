import EnvTools
import Foundation
import VaultCore

/// Pasted `KEY=value` lines (1.0 N2; board Place-Paste), read with the `.env` parser: the text
/// turns into lines only when every line is a comment, blank or such a line with a name the
/// place accepts, so a URL or a sentence pastes as text.
enum NotesPasteParser {
    struct Entry {
        /// As the place saves it (capitals; a Key Vault's dashes as underscores).
        let name: String
        let value: SecretBytes
    }

    /// The entries, or nil when the text is not only `KEY=value` lines. The caller wipes the values.
    static func entries(in text: String, place: NotesEditPlaceKind) -> [Entry]? {
        let contents = SecretBytes(utf8: text)
        defer { contents.wipe() }
        let result: DotEnvParseResult
        do {
            result = try DotEnvParser.parse(contents)
        } catch {
            // Over the `.env` size limit: too large to be lines for a place, it pastes as text.
            return nil
        }
        guard !result.entries.isEmpty, !result.hasErrors, result.entries.allSatisfy({ place.nameProblem($0.key) == nil }) else {
            for entry in result.entries {
                entry.value.wipe()
            }
            return nil
        }
        return result.entries.map { Entry(name: place.normalizedName($0.key), value: $0.value) }
    }
}
