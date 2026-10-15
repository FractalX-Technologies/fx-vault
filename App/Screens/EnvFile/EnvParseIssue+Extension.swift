import EnvTools
import VaultCore
import VaultData

/// Localized text for the import sheet's parse issues, key fixes, credential hints and skip
/// reasons. Every text names keys and line numbers only, never values.
nonisolated extension EnvParseIssue {
    /// "Line 4 · API_KEY: …" style description of the issue.
    var localizedMessage: String {
        switch kind {
        case .missingEquals:
            String(localized: "envImport.issue.missingEquals", defaultValue: "No \"=\" on this line, so it was skipped.")
        case .emptyKey:
            String(localized: "envImport.issue.emptyKey", defaultValue: "The line starts with \"=\" and has no key, so it was skipped.")
        case .invalidKey:
            String(
                localized: "envImport.issue.invalidKey",
                defaultValue: "The key contains a control character or invalid text, so the line was skipped."
            )
        case .unterminatedQuote:
            String(
                localized: "envImport.issue.unterminatedQuote",
                defaultValue: "A quoted value is never closed, so it was skipped. Reading resumed on the next line."
            )
        case .unexpectedCharactersAfterQuote:
            String(
                localized: "envImport.issue.unexpectedCharactersAfterQuote",
                defaultValue: "Text follows the closing quote, so the line was skipped."
            )
        case .invalidEncoding:
            String(localized: "envImport.issue.invalidEncoding", defaultValue: "The value is not valid UTF-8 text, so the line was skipped.")
        case .unquotedMultilineValue:
            String(
                localized: "envImport.issue.unquotedMultiline",
                defaultValue: "The value is a key or certificate on several lines without quotes, so it was skipped up to its END line. Wrap the value in double quotes."
            )
        case .duplicateKey(let previousLine):
            String(
                localized: "envImport.issue.duplicateKey",
                defaultValue: "This key also appears on line \(previousLine). The later value is used."
            )
        case .variableExpansionNotSupported:
            String(
                localized: "envImport.issue.variableExpansion",
                defaultValue: "The value contains \"${\". Variables are not expanded: the text is kept as written."
            )
        case .unknownEscapeSequence:
            String(
                localized: "envImport.issue.unknownEscape",
                defaultValue: "The value contains an unknown backslash escape. The backslash is kept as written."
            )
        }
    }

    /// "Line 4" or "Line 4 · API_KEY".
    var localizedLocation: String {
        if let key {
            String(localized: "envImport.issue.locationWithKey", defaultValue: "Line \(line) · \(key)")
        } else {
            String(localized: "envImport.issue.location", defaultValue: "Line \(line)")
        }
    }
}

nonisolated extension CredentialReason {
    /// Why the row was pre-marked as a secret (§5.13).
    var envImportDescription: String {
        switch self {
        case .keyContains(let pattern):
            String(localized: "envImport.credential.keyContains", defaultValue: "The name contains \(pattern).")
        case .urlWithCredentials:
            String(localized: "envImport.credential.url", defaultValue: "The value is a URL with a user name or password.")
        case .pemBlock:
            String(localized: "envImport.credential.pem", defaultValue: "The value contains a PEM key or certificate.")
        case .jsonWebToken:
            String(localized: "envImport.credential.jwt", defaultValue: "The value looks like a JSON Web Token.")
        case .knownTokenPrefix(let prefix):
            String(localized: "envImport.credential.tokenPrefix", defaultValue: "The value starts like a \(prefix) token.")
        case .highEntropy:
            String(localized: "envImport.credential.entropy", defaultValue: "The value looks like a random key.")
        }
    }
}

nonisolated extension EnvImportSkipModel.Reason {
    var envImportDescription: String {
        switch self {
        case .invalidName(let error):
            error.localizedMessage
        case .invalidValue(let error):
            error.localizedMessage
        case .duplicateInImport:
            String(localized: "envImport.skip.duplicate", defaultValue: "Another row imports the same name.")
        case .existingItem:
            String(localized: "envImport.skip.existing", defaultValue: "Already in this scope; kept the existing value.")
        case .unknownCandidate:
            String(localized: "envImport.skip.unknown", defaultValue: "The row no longer matches the file.")
        }
    }
}

nonisolated extension ConfigKind {
    /// "Secret" / "Variable" for the import table's Kind column.
    var envImportTitle: String {
        switch self {
        case .secret: String(localized: "envImport.kind.secret", defaultValue: "Secret")
        case .variable: String(localized: "envImport.kind.variable", defaultValue: "Variable")
        }
    }
}

nonisolated extension EnvImportConflictChoice {
    var localizedTitle: String {
        switch self {
        case .skip: String(localized: "envImport.conflict.skip", defaultValue: "Skip")
        case .overwrite: String(localized: "envImport.conflict.overwrite", defaultValue: "Overwrite")
        }
    }
}
