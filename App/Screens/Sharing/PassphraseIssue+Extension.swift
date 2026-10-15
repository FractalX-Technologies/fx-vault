import SharingKit

nonisolated extension PassphraseIssue {
    /// Format help for a typed passphrase. Never repeats the typed words.
    var localizedMessage: String {
        switch self {
        case .wrongWordCount(let found):
            String(
                localized: "share.passphrase.wordCount",
                defaultValue: "Enter all 6 words (\(found) entered)."
            )
        case .unknownWord(let position):
            String(
                localized: "share.passphrase.unknownWord",
                defaultValue: "Word \(position + 1) is not a passphrase word. Check its spelling."
            )
        }
    }
}
