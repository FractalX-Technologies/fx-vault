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
    /// assignment: a connection string (`Endpoint=sb://…;SharedAccessKey=…`) or a key as its name.
    private static func isEncodedLine(_ text: String, entries: [DotEnvEntryModel]) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entries.count == 1, let entry = entries.first, !line.contains(where: \.isNewline),
              let equals = line.firstIndex(of: "="), line[..<equals] == entry.key else { return false }
        let name = entry.key
        let isConnectionString = name.contains(where: \.isLowercase) && entry.value.withUnsafeBytes { bytes in
            bytes.contains(UInt8(ascii: ";")) && bytes.contains(UInt8(ascii: "="))
        }
        return isConnectionString || looksLikeValue(name)
    }

    /// A segment of snake case this long with a digit is a token's body (`shpat_` + 32 hex).
    static let tokenSegmentMinLength = 16
    /// A word this long in both cases with a digit is a key even below the entropy check's 20.
    static let shortKeyMinLength = 8

    /// Text that passes as a name but is a value (`CredentialClassifier`, §5.13): a known token
    /// (`ghp_…`, `xoxb-…`) or a random-looking one with a lowercase letter (Base64, hex). Snake
    /// case in one case stays a name unless a segment is a token's body (`aws_s3_bucket_name_2`
    /// stays, `sbp_` + 40 hex does not); uppercase Base32 stays a name too (tasks/waivers.md).
    static func looksLikeValue(_ text: String) -> Bool {
        let reasons = CredentialClassifier.valueReasons(in: text)
        if reasons.contains(where: { $0 != .highEntropy }) {
            return true
        }
        guard reasons.contains(.highEntropy), text.contains(where: \.isLowercase) else { return false }
        guard text.contains("_"), !text.contains(where: \.isUppercase) else { return true }
        return text.split(separator: "_").contains { $0.count >= tokenSegmentMinLength && $0.contains(where: \.isNumber) }
    }

    /// One pasted word (a trailing `=` aside) that is a value: ``looksLikeValue(_:)``, Base64
    /// with its padding, or a short key (8+ characters, no `_` or `-`, both cases and a digit:
    /// `r8Kq2mXz9TfA`). A Key Vault name like `DbPassword1` opens Set value… too; the user
    /// cancels it and types the name.
    static func isValue(pastedWord word: String) -> Bool {
        let body = word.hasSuffix("=") ? String(word.dropLast()) : word
        let hasBothCases = body.contains(where: \.isLowercase) && body.contains(where: \.isUppercase)
        let isPaddedBase64 = word.hasSuffix("=") && word.count.isMultiple(of: 4) && hasBothCases
        let isShortKey = body.count >= shortKeyMinLength && !body.contains("_") && !body.contains("-")
            && hasBothCases && body.contains(where: \.isNumber)
        return isPaddedBase64 || isShortKey || looksLikeValue(body)
    }
}
