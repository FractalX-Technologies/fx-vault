import Foundation

/// Provider rules for destination items and targets (v0.8.0, tasks/todo.md R3).
///
/// Item names keep GitHub's rules everywhere (``GitHubNameValidator``), so an item can be copied
/// between repositories, folders and destinations; each provider adds its own on top. Key Vault
/// names allow only letters, digits and dashes, so FX Vault maps `_` to `-` on the way out and
/// back on the way in.
public enum DestinationRules {
    /// Prefix Supabase reserves for its own secrets.
    public static let supabaseReservedPrefix = "SUPABASE_"
    /// Longest Key Vault secret name (Azure: 1–127 characters).
    public static let maxKeyVaultNameLength = 127
    /// Key Vault vault names: 3–24 characters.
    public static let keyVaultVaultNameLengths = 3...24
    /// Supabase project references: 20 lowercase letters.
    public static let supabaseProjectRefLength = 20
    /// Longest Vercel project or team identifier FX Vault accepts. Local choice.
    public static let maxVercelIdentifierLength = 100

    // MARK: - Item names

    /// The name the provider stores for `name` (already valid for GitHub): Key Vault gets dashes
    /// for underscores; Supabase and Vercel keep it.
    public static func remoteName(for name: String, provider: DestinationProvider) -> String {
        switch provider {
        case .azureKeyVault: name.replacingOccurrences(of: "_", with: "-")
        case .supabase, .vercel: name
        }
    }

    /// FX Vault's name for a name the provider listed, or nil when it cannot become a valid
    /// name (the caller lists such items as not usable with ``unusableReason(forRemoteName:provider:)``).
    public static func localName(forRemoteName remoteName: String, provider: DestinationProvider) -> String? {
        let candidate: String
        switch provider {
        case .azureKeyVault:
            candidate = remoteName.replacingOccurrences(of: "-", with: "_").uppercased()
        case .supabase, .vercel:
            // Case-sensitive providers: a lowercase key is another key than its uppercase form.
            guard remoteName == remoteName.uppercased() else { return nil }
            candidate = remoteName
        }
        guard GitHubNameValidator.isValid(candidate), violation(of: candidate, kind: .secret, provider: provider) == nil else {
            return nil
        }
        return candidate
    }

    /// Why a listed remote name cannot be used, or nil when ``localName(forRemoteName:provider:)``
    /// accepts it.
    public static func unusableReason(forRemoteName remoteName: String, provider: DestinationProvider) -> ValidationError? {
        guard localName(forRemoteName: remoteName, provider: provider) == nil else { return nil }
        if provider != .azureKeyVault, remoteName != remoteName.uppercased() {
            return .invalidName(.notUppercase)
        }
        let candidate = provider == .azureKeyVault
            ? remoteName.replacingOccurrences(of: "-", with: "_").uppercased()
            : remoteName
        if let rule = GitHubNameValidator.violation(in: candidate) {
            return .invalidName(rule)
        }
        return violation(of: candidate, kind: .secret, provider: provider) ?? .invalidName(.invalidCharacter)
    }

    /// The first provider rule `name` (valid for GitHub) and `kind` break, or nil.
    ///
    /// - Key Vault and Supabase hold secrets only (``ValidationError/kindNotSupported``).
    /// - Supabase reserves `SUPABASE_`.
    /// - Key Vault names are at most 127 characters.
    public static func violation(of name: String, kind: ConfigKind, provider: DestinationProvider) -> ValidationError? {
        if kind == .variable, !provider.holdsVariables {
            return .kindNotSupported
        }
        switch provider {
        case .azureKeyVault:
            if name.count > maxKeyVaultNameLength {
                return .invalidName(.tooLong(maxLength: maxKeyVaultNameLength))
            }
        case .supabase:
            if name.hasPrefix(supabaseReservedPrefix) {
                return .invalidName(.reservedByProvider)
            }
        case .vercel:
            break
        }
        return nil
    }

    /// Validates a name for a destination: GitHub's rules, then the provider's.
    @discardableResult
    public static func validate(_ name: String, kind: ConfigKind, provider: DestinationProvider) throws(ValidationError) -> String {
        let valid = try GitHubNameValidator.validate(name)
        if let error = violation(of: valid, kind: kind, provider: provider) {
            throw error
        }
        return valid
    }

    // MARK: - Values

    /// Largest value the provider accepts, in bytes (Key Vault: 25 KiB; the others: GitHub's
    /// limit, so a value that fits GitHub fits everywhere).
    public static func maxValueBytes(for provider: DestinationProvider) -> Int {
        switch provider {
        case .azureKeyVault: Limits.maxKeyVaultValueBytes
        case .supabase, .vercel: Limits.maxValueBytes
        }
    }

    // MARK: - Targets

    /// Validates a target's identifiers and returns it with names trimmed.
    public static func validate(_ target: DestinationTargetModel) throws(ValidationError) -> DestinationTargetModel {
        switch target {
        case .azureKeyVault(let vaultName, let tenantID):
            let name = vaultName.trimmingCharacters(in: .whitespaces)
            guard isValidKeyVaultName(name) else { throw .invalidDestinationTarget(.keyVaultName) }
            let tenant = tenantID?.trimmingCharacters(in: .whitespaces)
            if let tenant, !tenant.isEmpty, !isValidTenantID(tenant) {
                throw .invalidDestinationTarget(.tenantID)
            }
            return .azureKeyVault(vaultName: name, tenantID: tenant?.isEmpty == false ? tenant : nil)
        case .supabase(let projectRef):
            let ref = projectRef.trimmingCharacters(in: .whitespaces)
            guard isValidSupabaseProjectRef(ref) else { throw .invalidDestinationTarget(.supabaseProjectRef) }
            return .supabase(projectRef: ref)
        case .vercel(let projectID, let projectName, let teamID, let environment):
            guard isValidVercelIdentifier(projectID), isValidVercelIdentifier(projectName) else {
                throw .invalidDestinationTarget(.vercelProject)
            }
            if let teamID, !isValidVercelIdentifier(teamID) {
                throw .invalidDestinationTarget(.vercelTeam)
            }
            return .vercel(projectID: projectID, projectName: projectName, teamID: teamID, environment: environment)
        }
    }

    /// 3–24 letters, digits and dashes; starts with a letter; ends with a letter or digit; no
    /// two dashes in a row (Azure's vault naming rules).
    public static func isValidKeyVaultName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard keyVaultVaultNameLengths.contains(scalars.count),
              let first = scalars.first, let last = scalars.last,
              ASCIIClass.isLetter(first), ASCIIClass.isLetter(last) || ASCIIClass.isDigit(last) else {
            return false
        }
        var previousWasDash = false
        for scalar in scalars {
            let isDash = scalar == "-"
            guard ASCIIClass.isLetter(scalar) || ASCIIClass.isDigit(scalar) || isDash else { return false }
            if isDash, previousWasDash { return false }
            previousWasDash = isDash
        }
        return true
    }

    /// A Microsoft Entra tenant id (a UUID) or a domain such as `contoso.onmicrosoft.com`.
    public static func isValidTenantID(_ tenant: String) -> Bool {
        if UUID(uuidString: tenant) != nil { return true }
        let scalars = Array(tenant.unicodeScalars)
        guard (1...maxVercelIdentifierLength).contains(scalars.count), tenant.contains("."),
              let first = scalars.first, first != ".", first != "-" else {
            return false
        }
        return scalars.allSatisfy { ASCIIClass.isLetter($0) || ASCIIClass.isDigit($0) || $0 == "." || $0 == "-" }
    }

    /// Exactly 20 lowercase ASCII letters.
    public static func isValidSupabaseProjectRef(_ ref: String) -> Bool {
        let scalars = Array(ref.unicodeScalars)
        return scalars.count == supabaseProjectRefLength && scalars.allSatisfy { ("a"..."z").contains($0) }
    }

    /// 1–100 characters of letters, digits, `.`, `_` and `-` (Vercel project names are
    /// lowercase; ids such as `prj_…` and `team_…` mix cases).
    public static func isValidVercelIdentifier(_ identifier: String) -> Bool {
        let scalars = Array(identifier.unicodeScalars)
        guard (1...maxVercelIdentifierLength).contains(scalars.count) else { return false }
        return scalars.allSatisfy { ASCIIClass.isLetter($0) || ASCIIClass.isDigit($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }
}

/// Name prefixes that frameworks expose to the browser or the app bundle at build time
/// (tasks/todo.md R10). A value under one of them is public, whatever its kind.
public enum PublicNamePrefixes {
    /// Next.js, Vite, Expo, SvelteKit/Astro, Create React App, Nuxt and Gatsby.
    public static let all = ["NEXT_PUBLIC_", "VITE_", "EXPO_PUBLIC_", "PUBLIC_", "REACT_APP_", "NUXT_PUBLIC_", "GATSBY_"]

    /// The public prefix `name` starts with, or nil.
    public static func prefix(of name: String) -> String? {
        all.first { name.hasPrefix($0) }
    }
}

/// ASCII character classes for identifiers that must stay ASCII.
enum ASCIIClass {
    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }
}
