import Foundation

/// Provider rules for destination items and targets (v0.8.0, tasks/todo.md R3).
///
/// Item names keep GitHub's rules everywhere (``GitHubNameValidator``), so an item can be copied
/// between repositories, folders and destinations; each provider adds its own on top. Key Vault
/// names allow only letters, digits and dashes, so FX Vault maps `_` to `-` on the way out and
/// back on the way in.
public enum DestinationRules {
    /// Longest Key Vault secret name (Azure: 1–127 characters).
    public static let maxKeyVaultNameLength = 127
    /// Key Vault vault names: 3–24 characters.
    public static let keyVaultVaultNameLengths = 3...24
    /// Longest tenant domain FX Vault accepts. Local choice.
    public static let maxTenantDomainLength = 100

    // MARK: - Item names

    /// The name the provider stores for `name` (already valid for GitHub): Key Vault gets dashes
    /// for underscores.
    public static func remoteName(for name: String, provider: DestinationProvider) -> String {
        switch provider {
        case .azureKeyVault: name.replacingOccurrences(of: "_", with: "-")
        }
    }

    /// FX Vault's name for a name the provider listed, or nil when it cannot become a valid
    /// name (the caller lists such items as not usable with ``unusableReason(forRemoteName:provider:)``).
    public static func localName(forRemoteName remoteName: String, provider: DestinationProvider) -> String? {
        let candidate = remoteName.replacingOccurrences(of: "-", with: "_").uppercased()
        guard GitHubNameValidator.isValid(candidate), violation(of: candidate, kind: .secret, provider: provider) == nil else {
            return nil
        }
        return candidate
    }

    /// Why a listed remote name cannot be used, or nil when ``localName(forRemoteName:provider:)``
    /// accepts it.
    public static func unusableReason(forRemoteName remoteName: String, provider: DestinationProvider) -> ValidationError? {
        guard localName(forRemoteName: remoteName, provider: provider) == nil else { return nil }
        let candidate = remoteName.replacingOccurrences(of: "-", with: "_").uppercased()
        if let rule = GitHubNameValidator.violation(in: candidate) {
            return .invalidName(rule)
        }
        return violation(of: candidate, kind: .secret, provider: provider) ?? .invalidName(.invalidCharacter)
    }

    /// The first provider rule `name` (valid for GitHub) and `kind` break, or nil.
    ///
    /// - Key Vault holds secrets only (``ValidationError/kindNotSupported``).
    /// - Key Vault names are at most 127 characters.
    public static func violation(of name: String, kind: ConfigKind, provider: DestinationProvider) -> ValidationError? {
        if kind == .variable {
            return .kindNotSupported
        }
        if name.count > maxKeyVaultNameLength {
            return .invalidName(.tooLong(maxLength: maxKeyVaultNameLength))
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

    /// Largest value the provider accepts, in bytes (Key Vault: 25 KiB).
    public static func maxValueBytes(for provider: DestinationProvider) -> Int {
        switch provider {
        case .azureKeyVault: Limits.maxKeyVaultValueBytes
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
        guard (1...maxTenantDomainLength).contains(scalars.count), tenant.contains("."),
              let first = scalars.first, first != ".", first != "-" else {
            return false
        }
        return scalars.allSatisfy { ASCIIClass.isLetter($0) || ASCIIClass.isDigit($0) || $0 == "." || $0 == "-" }
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
