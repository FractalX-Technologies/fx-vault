import VaultCore

nonisolated extension ValidationError {
    var localizedMessage: String {
        switch self {
        case .invalidName(let rule):
            rule.localizedMessage
        case .invalidPathSegment:
            String(
                localized: "error.validation.invalidPathSegment",
                defaultValue: "This name contains characters that cannot be used in a path."
            )
        case .invalidHost:
            String(localized: "error.validation.invalidHost", defaultValue: "Only github.com is supported.")
        case .valueTooLarge(let limit):
            String(
                localized: "error.validation.valueTooLarge",
                defaultValue: "The value is larger than the limit of \(limit) bytes."
            )
        case .emptyValue:
            String(localized: "error.validation.emptyValue", defaultValue: "Enter a value. GitHub does not store empty values.")
        case .scopeFull(_, let limit):
            String(
                localized: "error.validation.scopeFull",
                defaultValue: "This scope already holds the maximum of \(limit) items."
            )
        case .duplicateName:
            String(localized: "error.validation.duplicateName", defaultValue: "Another item already uses this name.")
        case .nameReservedByPendingChange:
            String(
                localized: "error.validation.nameReservedByPendingChange",
                defaultValue: "This name is still used by a pending rename or deletion. Sync or revert that change first."
            )
        case .lockedAfterSync:
            String(
                localized: "error.validation.lockedAfterSync",
                defaultValue: "The kind and scope cannot change after the item is on GitHub."
            )
        case .kindNotSupported:
            String(
                localized: "error.validation.kindNotSupported",
                defaultValue: "This destination holds secrets only. Add it as a secret."
            )
        case .invalidDestinationTarget(let rule):
            rule.localizedMessage
        }
    }
}

nonisolated extension DestinationTargetRule {
    var localizedMessage: String {
        switch self {
        case .keyVaultName:
            String(
                localized: "error.destination.keyVaultName",
                defaultValue: "Key Vault names have 3 to 24 letters, digits and dashes, start with a letter and have no two dashes in a row."
            )
        case .tenantID:
            String(
                localized: "error.destination.tenantID",
                defaultValue: "Enter a tenant ID (a UUID) or a domain such as contoso.onmicrosoft.com, or leave it empty."
            )
        case .supabaseProjectRef:
            String(
                localized: "error.destination.supabaseProjectRef",
                defaultValue: "A Supabase project reference is 20 lowercase letters."
            )
        case .vercelProject:
            String(localized: "error.destination.vercelProject", defaultValue: "Choose a Vercel project.")
        case .vercelTeam:
            String(localized: "error.destination.vercelTeam", defaultValue: "Choose a Vercel team or your personal account.")
        }
    }
}

nonisolated extension NameRule {
    var localizedMessage: String {
        switch self {
        case .empty:
            String(localized: "error.name.empty", defaultValue: "Enter a name.")
        case .tooLong(let maxLength):
            String(localized: "error.name.tooLong", defaultValue: "Use at most \(maxLength) characters.")
        case .invalidCharacter:
            String(localized: "error.name.invalidCharacter", defaultValue: "The name contains a character that is not allowed.")
        case .invalidFirstCharacter:
            String(localized: "error.name.invalidFirstCharacter", defaultValue: "The name cannot start with this character.")
        case .leadingDigit:
            String(localized: "error.name.leadingDigit", defaultValue: "The name cannot start with a digit.")
        case .reservedPrefix:
            String(localized: "error.name.reservedPrefix", defaultValue: "Names starting with GITHUB_ are reserved by GitHub.")
        case .reservedName:
            String(localized: "error.name.reservedName", defaultValue: "FX Vault reserves this name.")
        case .reservedByProvider:
            String(localized: "error.name.reservedByProvider", defaultValue: "Names starting with SUPABASE_ are reserved by Supabase.")
        case .notUppercase:
            String(
                localized: "error.name.notUppercase",
                defaultValue: "The name has lowercase letters. FX Vault keeps names in uppercase, so it leaves this one as it is."
            )
        case .dotName:
            String(localized: "error.name.dotName", defaultValue: "The name cannot be . or ..")
        case .gitSuffix:
            String(localized: "error.name.gitSuffix", defaultValue: "The name cannot end with .git")
        case .controlCharacter:
            String(localized: "error.name.controlCharacter", defaultValue: "The name contains a control character.")
        case .bidiCharacter:
            String(localized: "error.name.bidiCharacter", defaultValue: "The name contains a text-direction character.")
        case .zeroWidthCharacter:
            String(localized: "error.name.zeroWidthCharacter", defaultValue: "The name contains an invisible character.")
        case .leadingOrTrailingWhitespace:
            String(localized: "error.name.whitespace", defaultValue: "The name cannot start or end with a space.")
        case .notNormalized:
            String(localized: "error.name.notNormalized", defaultValue: "The name uses an unusual Unicode form.")
        }
    }
}
