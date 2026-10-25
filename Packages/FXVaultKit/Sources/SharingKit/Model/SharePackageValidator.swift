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
    /// An environment has no branch policy where one is required: in a schema v1 package, in an
    /// `environment`-scope package, or when it carries no items (a partial environment must
    /// carry at least one item).
    case branchPolicyRequired
    /// A folder's name failed ``FolderNameValidator`` in strict NFC mode (v0.7.0).
    case invalidFolderName(ValidationError)
    /// A folder holds more than `limit` secrets and variables (v0.7.0).
    case tooManyFolderItems(limit: Int)

    // MARK: Bundles (schema 4, v0.9.0)

    /// An item of a schema 1–3 document carries a `link` token.
    case linkNotAllowed
    /// A `link` token is not a lowercase UUID, or fewer than two items of the bundle carry it.
    case invalidLinkToken
    /// The bundle holds neither a repository nor a folder.
    case emptyBundle
    /// The bundle holds more than `limit` repositories (``Limits/maxShareRepositories``).
    case tooManyRepositories(limit: Int)
    /// Two repositories of the bundle have the same owner and name (case-insensitive).
    case duplicateRepository
    /// `expiresAt` is not after `createdAt`, or later than ``Timeouts/shareMaxExpiry`` after it.
    case invalidExpiry
    /// `createdAt` is ahead of this Mac's clock by more than ``Timeouts/shareClockSkew``.
    case createdInFuture
    /// A name in `stages` failed ``EnvironmentNameValidator`` in strict NFC mode.
    case invalidStage(ValidationError)
    /// `stages` lists the same stage twice (case-insensitive).
    case duplicateStage
    /// A destination's target or stage failed ``DestinationRules`` (or the environment name rules
    /// for the stage), or is not already in its trimmed form.
    case invalidDestinationTarget(ValidationError)
    /// Two destinations of one repository have the same target key.
    case duplicateDestination
    /// A repository carries more than `limit` destinations (``Limits/maxDestinationsPerRepository``).
    case tooManyDestinations(limit: Int)
    /// A destination item breaks a provider rule (``DestinationRules/violation(of:kind:provider:)``,
    /// a value above the provider's size limit).
    case invalidDestinationItem(ValidationError)
    /// Two items of one destination have the same name, whatever their kind.
    case duplicateDestinationItem
    /// A destination holds more than `limit` items (``Limits/maxDestinationItems``).
    case tooManyDestinationItems(limit: Int)
    /// Two folders of the bundle have the same name (case-insensitive).
    case duplicateFolder
}

/// Checks every §9.3 rule on a decoded or about-to-be-sent package (schema v1 and v2, and v3
/// folders: a valid folder name, no repository or environments, at most
/// ``Limits/maxFolderItems`` items, every item with a value).
///
/// Run on every boundary: after decrypting a `.fxvault`, on a preview manifest, and before
/// exporting.
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
        if !SharePackageModel.supportedSchemaVersions.contains(package.schemaVersion) {
            return .unsupportedSchemaVersion(package.schemaVersion)
        }
        if let violation = producerViolation(package.producer) { return violation }
        if !isSanitized(package.sender.displayName) { return .invalidSenderName }
        if package.isFolder || package.folder != nil {
            return folderViolation(package, mode: mode)
        }
        if !SharePackageModel.repositorySchemaVersions.contains(package.schemaVersion) {
            return .unsupportedSchemaVersion(package.schemaVersion)
        }
        if let violation = repositoryViolation(package.repository) { return violation }
        if let violation = entryIDViolation(package) { return violation }
        if let violation = itemsViolation(package.repository, mode: mode, allowsLink: false) { return violation }
        if let violation = partialEnvironmentViolation(package) { return violation }
        return scopeViolation(package)
    }

    // MARK: - Folders (v0.7.0)

    private static func folderViolation(_ package: SharePackageModel, mode: Mode) -> SharePackageViolation? {
        let repository = package.repository
        guard package.isFolder,
              let folder = package.folder,
              package.schemaVersion >= SharePackageModel.folderSchemaVersion,
              repository.host == GitHubHostValidator.host,
              repository.owner.isEmpty,
              repository.name.isEmpty,
              repository.githubRepoID == nil,
              repository.environments.isEmpty
        else { return .scopeMismatch(package.scope) }
        if let error = FolderNameValidator.violation(in: folder.name, requireNFC: true) {
            return .invalidFolderName(error)
        }
        if package.itemCount > Limits.maxFolderItems {
            return .tooManyFolderItems(limit: Limits.maxFolderItems)
        }
        if let violation = entryIDViolation(package) { return violation }
        for (items, kind) in [(repository.secrets, ConfigKind.secret), (repository.variables, .variable)] {
            var keys = Set<String>()
            for item in items {
                guard item.valueState == .present else { return .valueStateMismatch }
                if let violation = itemViolation(item, mode: mode, allowsLink: false) { return violation }
                guard keys.insert(GitHubNameValidator.foldKey(item.name)).inserted else {
                    return .duplicateItem(kind: kind, level: .repository)
                }
            }
        }
        return nil
    }

    // MARK: - Header fields

    static func producerViolation(_ producer: ShareProducerModel) -> SharePackageViolation? {
        for field in [producer.app, producer.version] {
            let isValid = !field.isEmpty
                && field.utf8.count <= maxProducerFieldBytes
                && isSanitized(field)
            if !isValid { return .invalidProducer }
        }
        return nil
    }

    static func isSanitized(_ text: String) -> Bool {
        DisplayNameSanitizer.sanitize(text) == text
    }

    static func repositoryViolation(_ repository: ShareRepositoryModel) -> SharePackageViolation? {
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
            if let policy = environment.deploymentBranchPolicy, let violation = policyViolation(policy) {
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

    static func itemsViolation(
        _ repository: ShareRepositoryModel,
        mode: Mode,
        allowsLink: Bool
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
            if let violation = scopeItemsViolation(
                scope.items,
                kind: scope.kind,
                level: scope.level,
                mode: mode,
                allowsLink: allowsLink
            ) {
                return violation
            }
        }
        return nil
    }

    private static func scopeItemsViolation(
        _ items: [ShareItemModel],
        kind: ConfigKind,
        level: ConfigScopeLevel,
        mode: Mode,
        allowsLink: Bool
    ) -> SharePackageViolation? {
        let limit = Limits.maxItems(kind: kind, level: level)
        if items.count > limit { return .tooManyItems(kind: kind, level: level, limit: limit) }
        var keys = Set<String>()
        for item in items {
            if let violation = itemViolation(item, mode: mode, allowsLink: allowsLink) { return violation }
            guard keys.insert(GitHubNameValidator.foldKey(item.name)).inserted else {
                return .duplicateItem(kind: kind, level: level)
            }
        }
        return nil
    }

    /// Name, link and value rules of one item. `allowsLink` is true only inside a bundle.
    static func itemViolation(_ item: ShareItemModel, mode: Mode, allowsLink: Bool) -> SharePackageViolation? {
        if item.linkToken != nil, !allowsLink { return .linkNotAllowed }
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

    /// `valueState` against `value`, UTF-8, emptiness and GitHub's size limit (`maxValueBytes`
    /// for destination items, v0.9.0).
    static func valueViolation(_ item: ShareItemModel, maxValueBytes: Int = Limits.maxValueBytes) -> SharePackageViolation? {
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
            return normalizedCount > maxValueBytes ? .valueTooLarge(limit: maxValueBytes) : nil
        default:
            return .valueStateMismatch
        }
    }

    // MARK: - Partial environments

    /// A missing branch policy needs schema v2 and at least one item in the environment.
    private static func partialEnvironmentViolation(_ package: SharePackageModel) -> SharePackageViolation? {
        let allowsPartial = package.schemaVersion >= SharePackageModel.partialEnvironmentsSchemaVersion
        return partialEnvironmentViolation(package.repository, allowsPartial: allowsPartial)
    }

    /// Every environment without a branch policy must be allowed and carry at least one item.
    static func partialEnvironmentViolation(_ repository: ShareRepositoryModel, allowsPartial: Bool) -> SharePackageViolation? {
        let partial = repository.environments.filter { !$0.includesBranchPolicy }
        guard !partial.isEmpty else { return nil }
        let isValid = allowsPartial && partial.allSatisfy { $0.itemCount > 0 }
        return isValid ? nil : .branchPolicyRequired
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
            guard repository.environments.allSatisfy(\.includesBranchPolicy) else { return .branchPolicyRequired }
            isValid = repositoryItemCount == 0 && repository.environments.count == 1
        case .repository:
            isValid = true
        case .folder:
            isValid = false
        }
        return isValid ? nil : .scopeMismatch(package.scope)
    }
}
