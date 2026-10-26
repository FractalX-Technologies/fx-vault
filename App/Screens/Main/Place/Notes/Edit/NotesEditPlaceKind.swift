import Foundation
import VaultCore

/// Where the notes are edited (1.0 N2), and so which rules their names and values follow: a
/// repository scope and a folder take GitHub's, a Key Vault adds its own (`DestinationRules`).
enum NotesEditPlaceKind: Hashable {
    case repository
    case folder
    case keyVault

    /// The sections the notes hold: a Key Vault holds secrets only.
    var kinds: [ConfigKind] {
        self == .keyVault ? [.secret] : ConfigKind.allCases
    }

    /// The largest value, after the trailing CR/LF are stripped (D32).
    var maxValueBytes: Int {
        self == .keyVault ? DestinationRules.maxValueBytes(for: .azureKeyVault) : Limits.maxValueBytes
    }

    /// The name FX Vault saves for `typed`: capitals, and a Key Vault's dashes as underscores.
    func normalizedName(_ typed: String) -> String {
        self == .keyVault ? DestinationRules.localCandidate(forRemoteName: typed) : GitHubNameValidator.normalize(typed)
    }

    /// The name Key Vault stores for `name` (`CACHE_URL` → `CACHE-URL`); nil elsewhere.
    func remoteName(_ name: String) -> String? {
        self == .keyVault ? DestinationRules.remoteName(for: name, provider: .azureKeyVault) : nil
    }

    /// What is wrong with `typed` as a name, as a line's note; nil when it can be saved.
    func nameProblem(_ typed: String) -> String? {
        // A Key Vault name is typed as Key Vault writes it: its dashes are not the error.
        let candidate = self == .keyVault ? DestinationRules.localCandidate(forRemoteName: typed) : typed
        if let rule = GitHubNameValidator.violation(in: candidate) {
            return Self.message(for: rule)
        }
        if self == .keyVault, candidate.count > DestinationRules.maxKeyVaultNameLength {
            return NotesEditCopy.keyVaultTooLong(DestinationRules.maxKeyVaultNameLength)
        }
        return nil
    }

    /// The note for a value of `byteCount` bytes over ``maxValueBytes``; nil when it fits.
    func sizeProblem(byteCount: Int) -> String? {
        guard byteCount > maxValueBytes else { return nil }
        return NotesEditCopy.tooLarge(bytes: byteCount, limit: maxValueBytes, isKeyVault: self == .keyVault)
    }

    /// The board's short forms (Place-Errors); the rarer rules share "Use letters, digits and _".
    private static func message(for rule: NameRule) -> String {
        switch rule {
        case .empty: NotesEditCopy.addName
        case .leadingDigit, .invalidFirstCharacter: NotesEditCopy.leadingDigit
        case .reservedPrefix: NotesEditCopy.reservedPrefix
        case .reservedName: NotesEditCopy.reservedName
        case .tooLong(let maxLength): NotesEditCopy.tooLong(maxLength)
        case .invalidCharacter, .controlCharacter, .bidiCharacter, .zeroWidthCharacter, .leadingOrTrailingWhitespace,
             .notNormalized, .dotName, .gitSuffix:
            NotesEditCopy.lettersDigits
        }
    }
}
