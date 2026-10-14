import Foundation
import VaultCore

/// A broken `SharePackageValidator` rule (§9.3). Carries rule details, never names or values.
public enum SharePackageViolation: Sendable, Hashable {
    case unsupportedSchema
    case unsupportedSchemaVersion(Int)
    /// `producer.app` / `producer.version` is empty, too long or contains unsafe characters.
    case invalidProducer
    /// `sender.displayName` is not already sanitized (NFC, no control/bidi/zero-width,
    /// ≤ ``Limits/maxDisplayNameBytes``).
    case invalidSenderName
    /// The host is not exactly `github.com`.
    case invalidHost
    case invalidOwner(NameRule)
    case invalidRepositoryName(NameRule)
    case invalidGitHubRepoID
    /// A name failed ``PathSegmentValidator`` (D29).
    case invalidPathSegment(PathSegmentRule)
    /// An environment name failed ``EnvironmentNameValidator`` in strict NFC mode.
    case invalidEnvironmentName(ValidationError)
    /// A secret or variable name failed ``GitHubNameValidator`` or is not uppercase.
    case invalidItemName(NameRule)
    case duplicateEnvironment
    case duplicateItem(kind: ConfigKind, level: ConfigScopeLevel)
    case duplicateEntryID
    case tooManyItems(kind: ConfigKind, level: ConfigScopeLevel, limit: Int)
    /// A manifest must carry no values.
    case valueInManifest
    /// In a full package `valueState == .present` must come with a value and `.missing` without.
    case valueStateMismatch
    /// A value is empty once trailing CR/LF is stripped (D32).
    case emptyValue
    case valueTooLarge(limit: Int)
    /// A value is not valid UTF-8 (GitHub values are text).
    case valueNotUTF8
    case invalidPattern(NameRule)
    case tooManyPatterns(limit: Int)
    case duplicatePattern
    /// Patterns are only allowed with the `custom` policy.
    case patternsWithoutCustomPolicy
    /// The contents do not match `scope` (see ``ShareScope``).
    case scopeMismatch(ShareScope)
}

/// Checks every §9.3 rule on a decoded or about-to-be-sent package.
///
/// Run on every boundary: after decrypting a `.fxvault`, on a received nearby MANIFEST and
/// PAYLOAD, and before exporting.
public enum SharePackageValidator {
    /// What kind of document is being validated.
    public enum Mode: Sendable, Hashable {
        /// Every value must be null; `valueState` still tells which items have one.
        case manifest
        /// Values must match `valueState`.
        case payload
    }

    /// Longest accepted `githubRepoId` (GraphQL node ids are far shorter). Local choice.
    public static let maxGitHubRepoIDLength = 128
    /// Longest accepted `producer.app` / `producer.version`, in UTF-8 bytes. Local choice.
    public static let maxProducerFieldBytes = Limits.maxDisplayNameBytes

    /// Throws `.invalidPackage` with the first violation found.
    public static func validate(_ package: SharePackageModel, mode: Mode) throws(ShareError) {
        if let violation = violation(in: package, mode: mode) {
            throw .invalidPackage(violation)
        }
    }

    /// The first violation, or nil when the package is valid.
    public static func violation(in package: SharePackageModel, mode: Mode) -> SharePackageViolation? {
        if package.schema != SharePackageModel.schemaIdentifier { return .unsupportedSchema }
        if package.schemaVersion != SharePackageModel.currentSchemaVersion {
            return .unsupportedSchemaVersion(package.schemaVersion)
        }
        if let violation = producerViolation(package.producer) { return violation }
        if !isSanitized(package.sender.displayName) { return .invalidSenderName }
        if let violation = repositoryViolation(package.repository) { return violation }
        if let violation = entryIDViolation(package) { return violation }
        if let violation = itemsViolation(package.repository, mode: mode) { return violation }
        return scopeViolation(package)
    }

    // MARK: - Header fields

    private static func producerViolation(_ producer: ShareProducerModel) -> SharePackageViolation? {
        for field in [producer.app, producer.version] {
            let isValid = !field.isEmpty
                && field.utf8.count <= maxProducerFieldBytes
                && isSanitized(field)
            if !isValid { return .invalidProducer }
        }
        return nil
    }

    private static func isSanitized(_ text: String) -> Bool {
        DisplayNameSanitizer.sanitize(text) == text
    }

    private static func repositoryViolation(_ repository: ShareRepositoryModel) -> SharePackageViolation? {
        if repository.host != GitHubHostValidator.host { return .invalidHost }
        if let rule = OwnerLoginValidator.violation(in: repository.owner) { return .invalidOwner(rule) }
        if let rule = PathSegmentValidator.violation(in: repository.owner) {
            return .invalidPathSegment(rule)
        }
        if let rule = RepoNameValidator.violation(in: repository.name) {
            return .invalidRepositoryName(rule)
        }
        if let rule = PathSegmentValidator.violation(in: repository.name) {
            return .invalidPathSegment(rule)
        }
        if let id = repository.githubRepoID, !isValidGitHubRepoID(id) { return .invalidGitHubRepoID }
        return environmentsViolation(repository.environments)
    }

    /// GraphQL node ids are ASCII letters, digits, `_`, `-`, `=`, `+` and `/` (legacy base64).
    private static func isValidGitHubRepoID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maxGitHubRepoIDLength else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic
                || ("0"..."9").contains(scalar)
                || "_-=+/".unicodeScalars.contains(scalar))
        }
    }

    private static func environmentsViolation(
        _ environments: [ShareEnvironmentModel]
    ) -> SharePackageViolation? {
        var keys = Set<String>()
        for environment in environments {
            if let error = EnvironmentNameValidator.violation(in: environment.name, requireNFC: true) {
                return .invalidEnvironmentName(error)
            }
            if let rule = PathSegmentValidator.violation(in: environment.name) {
                return .invalidPathSegment(rule)
            }
            guard keys.insert(EnvironmentNameValidator.foldKey(environment.name)).inserted else {
                return .duplicateEnvironment
            }
            if let violation = policyViolation(environment.deploymentBranchPolicy) {
                return violation
            }
        }
        return nil
    }

    private static func policyViolation(_ policy: ShareBranchPolicyModel) -> SharePackageViolation? {
        if policy.type != .custom {
            return policy.patterns.isEmpty ? nil : .patternsWithoutCustomPolicy
        }
        if policy.patterns.count > Limits.maxBranchPatternsPerEnvironment {
            return .tooManyPatterns(limit: Limits.maxBranchPatternsPerEnvironment)
        }
        var seen = Set<ShareBranchPatternModel>()
        for pattern in policy.patterns {
            if let rule = BranchPatternValidator.violation(in: pattern.name) {
                return .invalidPattern(rule)
            }
            guard seen.insert(pattern).inserted else { return .duplicatePattern }
        }
        return nil
    }

    // MARK: - Entries and items

    private static func entryIDViolation(_ package: SharePackageModel) -> SharePackageViolation? {
        let environmentIDs = package.repository.environments.map(\.id)
        let itemIDs = package.flattenedItems.map(\.item.id)
        let all = environmentIDs + itemIDs
        return Set(all).count == all.count ? nil : .duplicateEntryID
    }

    private static func itemsViolation(
        _ repository: ShareRepositoryModel,
        mode: Mode
    ) -> SharePackageViolation? {
        var scopes: [(items: [ShareItemModel], kind: ConfigKind, level: ConfigScopeLevel)] = [
            (repository.secrets, .secret, .repository),
            (repository.variables, .variable, .repository),
        ]
        for environment in repository.environments {
            scopes.append((environment.secrets, .secret, .environment))
            scopes.append((environment.variables, .variable, .environment))
        }
        for scope in scopes {
            if let violation = scopeItemsViolation(scope.items, kind: scope.kind, level: scope.level, mode: mode) {
                return violation
            }
        }
        return nil
    }

    private static func scopeItemsViolation(
        _ items: [ShareItemModel],
        kind: ConfigKind,
        level: ConfigScopeLevel,
        mode: Mode
    ) -> SharePackageViolation? {
        let limit = Limits.maxItems(kind: kind, level: level)
        if items.count > limit { return .tooManyItems(kind: kind, level: level, limit: limit) }
        var keys = Set<String>()
        for item in items {
            if let violation = itemViolation(item, mode: mode) { return violation }
            guard keys.insert(GitHubNameValidator.foldKey(item.name)).inserted else {
                return .duplicateItem(kind: kind, level: level)
            }
        }
        return nil
    }

    private static func itemViolation(_ item: ShareItemModel, mode: Mode) -> SharePackageViolation? {
        if let rule = GitHubNameValidator.violation(in: item.name) { return .invalidItemName(rule) }
        if GitHubNameValidator.normalize(item.name) != item.name {
            return .invalidItemName(.notNormalized)
        }
        if let rule = PathSegmentValidator.violation(in: item.name) { return .invalidPathSegment(rule) }
        switch mode {
        case .manifest:
            return item.value == nil ? nil : .valueInManifest
        case .payload:
            return valueViolation(item)
        }
    }

    private static func valueViolation(_ item: ShareItemModel) -> SharePackageViolation? {
        switch (item.valueState, item.value) {
        case (.missing, nil):
            return nil
        case (.present, .some(let value)):
            let normalizedCount: Int? = value.withUnsafeBytes { bytes in
                guard String(bytes: bytes, encoding: .utf8) != nil else { return nil }
                return bytes.count - ValueNormalizer.trailingNewlineCount(in: bytes)
            }
            guard let normalizedCount else { return .valueNotUTF8 }
            do {
                try ValueNormalizer.validate(byteCount: normalizedCount)
            } catch {
                return error == .emptyValue ? .emptyValue : .valueTooLarge(limit: Limits.maxValueBytes)
            }
            return nil
        default:
            return .valueStateMismatch
        }
    }

    // MARK: - Scope rules

    private static func scopeViolation(_ package: SharePackageModel) -> SharePackageViolation? {
        let repository = package.repository
        let repositoryItemCount = repository.secrets.count + repository.variables.count
        let isValid: Bool
        switch package.scope {
        case .secret:
            let isSingleRepositoryItem = repositoryItemCount == 1 && repository.environments.isEmpty
            let isSingleEnvironmentItem = repositoryItemCount == 0
                && repository.environments.count == 1
                && package.itemCount == 1
            isValid = isSingleRepositoryItem || isSingleEnvironmentItem
        case .environment:
            isValid = repositoryItemCount == 0 && repository.environments.count == 1
        case .repository:
            isValid = true
        }
        return isValid ? nil : .scopeMismatch(package.scope)
    }
}
