import Foundation
import VaultCore

/// Removes secrets from gh, git and ssh stderr before it is displayed or logged
/// (tasks/todo.md §4.5).
///
/// Replaces, with ``GHConstants/redactionPlaceholder``:
/// - the current operation's plaintext values (the stdin value and the account token);
/// - GitHub token patterns `gh[opusr]_[A-Za-z0-9]{20,}` and `github_pat_[A-Za-z0-9_]{20,}`.
public enum StderrRedactor {
    /// Characters after a `ghX_` prefix before a match counts as a token.
    static let minimumTokenBodyLength = 20
    private static let classicPrefixLetters: Set<Character> = ["o", "p", "u", "s", "r"]
    private static let fineGrainedPrefix = "github_pat_"
    private static let classicPrefix = "gh"
    private static let classicSeparator: Character = "_"

    /// Redacts `text`. Each secret is matched by its UTF-8 text; secrets that are not valid
    /// UTF-8 cannot appear in decoded stderr and are skipped.
    public static func redact(_ text: String, secrets: [SecretBytes] = []) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            guard let plaintext = secret.utf8String(), !plaintext.isEmpty else { continue }
            result = result.replacingOccurrences(of: plaintext, with: GHConstants.redactionPlaceholder)
            let trimmed = plaintext.trimmingCharacters(in: .newlines)
            if trimmed != plaintext, !trimmed.isEmpty {
                result = result.replacingOccurrences(of: trimmed, with: GHConstants.redactionPlaceholder)
            }
        }
        return redactTokenPatterns(in: result)
    }

    /// Replaces every GitHub token pattern in `text`.
    public static func redactTokenPatterns(in text: String) -> String {
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var index = 0
        while index < characters.count {
            if let end = tokenEnd(in: characters, at: index) {
                output += GHConstants.redactionPlaceholder
                index = end
            } else {
                output.append(characters[index])
                index += 1
            }
        }
        return output
    }

    /// If a token starts at `start`, the index after it. Like the plan's regexes, there is no
    /// word-boundary requirement: a token glued to other text is still redacted.
    private static func tokenEnd(in characters: [Character], at start: Int) -> Int? {
        if matches(fineGrainedPrefix, in: characters, at: start) {
            let bodyStart = start + fineGrainedPrefix.count
            let end = scanBody(characters, from: bodyStart, allowUnderscore: true)
            return end - bodyStart >= minimumTokenBodyLength ? end : nil
        }
        let prefixLength = classicPrefix.count + 2
        guard start + prefixLength <= characters.count,
              matches(classicPrefix, in: characters, at: start),
              classicPrefixLetters.contains(characters[start + classicPrefix.count]),
              characters[start + classicPrefix.count + 1] == classicSeparator
        else { return nil }
        let bodyStart = start + prefixLength
        let end = scanBody(characters, from: bodyStart, allowUnderscore: false)
        return end - bodyStart >= minimumTokenBodyLength ? end : nil
    }

    private static func matches(_ prefix: String, in characters: [Character], at start: Int) -> Bool {
        let prefixCharacters = Array(prefix)
        guard start + prefixCharacters.count <= characters.count else { return false }
        return Array(characters[start..<(start + prefixCharacters.count)]) == prefixCharacters
    }

    private static func scanBody(_ characters: [Character], from start: Int, allowUnderscore: Bool) -> Int {
        var end = start
        while end < characters.count, isTokenBodyCharacter(characters[end], allowUnderscore: allowUnderscore) {
            end += 1
        }
        return end
    }

    private static func isTokenBodyCharacter(_ character: Character, allowUnderscore: Bool) -> Bool {
        guard character.isASCII else { return false }
        if character.isLetter || character.isNumber { return true }
        return allowUnderscore && character == "_"
    }
}
