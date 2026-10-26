import EnvTools
import Foundation
import VaultCore

/// Pasted `KEY=value` lines (1.0 N2; board Place-Paste), read with the `.env` parser: the text
/// turns into lines only when every line is a comment, blank or such a line with a name the
/// place accepts and a value, so a URL, a sentence or key material pastes as one value.
enum NotesPasteParser {
    struct Entry {
        /// As the place saves it (capitals; a Key Vault's dashes as underscores).
        let name: String
        let value: SecretBytes
    }

    /// Names a single encoded line could look like: no `_`, this long, a digit and a lowercase
    /// letter (Base64 or hex), which an environment variable's name hardly ever is.
    static let encodedNameMinLength = 16

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
        let isLines = !result.entries.isEmpty && !result.hasErrors
            && result.entries.allSatisfy { place.nameProblem($0.key) == nil && hasValue($0.value) }
            && !isEncodedLine(text, entries: result.entries)
        guard isLines else {
            for entry in result.entries {
                entry.value.wipe()
            }
            return nil
        }
        return result.entries.map { Entry(name: place.normalizedName($0.key), value: $0.value) }
    }

    /// Something besides `=`: `c2VjcmV0MTIz==` reads as the name `c2VjcmV0MTIz` with the value
    /// `=`, and names are plaintext on disk, in gh's arguments and on GitHub (SECURITY-MODEL §7).
    private static func hasValue(_ value: SecretBytes) -> Bool {
        value.withUnsafeBytes { bytes in
            bytes.contains { $0 != UInt8(ascii: "=") }
        }
    }

    /// One `name=value` line, no space around its `=`, that is key material rather than an
    /// assignment: a connection string (`Endpoint=sb://…;SharedAccessKey=…`) or a Base64 name.
    private static func isEncodedLine(_ text: String, entries: [DotEnvEntryModel]) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entries.count == 1, let entry = entries.first, !line.contains(where: \.isNewline),
              let equals = line.firstIndex(of: "="), line[..<equals] == entry.key else { return false }
        let name = entry.key
        let hasLowercase = name.contains(where: \.isLowercase)
        let isConnectionString = hasLowercase && entry.value.withUnsafeBytes { bytes in
            bytes.contains(UInt8(ascii: ";")) && bytes.contains(UInt8(ascii: "="))
        }
        let looksEncoded = name.count >= encodedNameMinLength && !name.contains("_")
            && hasLowercase && name.contains(where: \.isNumber)
        return isConnectionString || looksEncoded
    }
}
