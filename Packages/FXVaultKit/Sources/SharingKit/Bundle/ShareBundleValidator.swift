import Foundation
import VaultCore

/// Checks every rule of a schema 4 bundle (v0.9.0) on a decoded or about-to-be-sealed document.
///
/// On top of the schema 2 rules for each repository (``SharePackageValidator``): one or more
/// repositories (at most ``Limits/maxShareRepositories``) or at least one folder; unique
/// repositories, stages, destinations (by target key) and folders; destination targets and items
/// per ``DestinationRules``; `expiresAt` after `createdAt` and at most ``Timeouts/shareMaxExpiry``
/// later (plus ``Timeouts/shareClockSkew``); unique entry ids across the bundle; and every `link`
/// token a lowercase UUID shared by at least two items. Freshness against the clock is
/// ``ShareBundleModel/checkFreshness(now:)``.
public enum ShareBundleValidator {
    /// Throws `.invalidPackage` with the first violation found.
    public static func validate(_ bundle: ShareBundleModel, mode: SharePackageValidator.Mode) throws(ShareError) {
        if let violation = violation(in: bundle, mode: mode) {
            throw .invalidPackage(violation)
        }
    }

    /// The first violation, or nil when the bundle is valid.
    public static func violation(in bundle: ShareBundleModel, mode: SharePackageValidator.Mode) -> SharePackageViolation? {
        if bundle.schema != SharePackageModel.schemaIdentifier { return .unsupportedSchema }
        if bundle.schemaVersion != ShareBundleModel.schemaVersion {
            return .unsupportedSchemaVersion(bundle.schemaVersion)
        }
        if let violation = SharePackageValidator.producerViolation(bundle.producer) { return violation }
        if !SharePackageValidator.isSanitized(bundle.sender.displayName) { return .invalidSenderName }
        if let violation = expiryViolation(bundle) { return violation }
        if let violation = stagesViolation(bundle.stages) { return violation }
        if bundle.repositories.isEmpty, bundle.folders.isEmpty { return .emptyBundle }
        if bundle.repositories.count > Limits.maxShareRepositories {
            return .tooManyRepositories(limit: Limits.maxShareRepositories)
        }
        var repositoryKeys = Set<String>()
        for entry in bundle.repositories {
            guard repositoryKeys.insert(entry.id).inserted else { return .duplicateRepository }
            if let violation = repositoryViolation(entry, mode: mode) { return violation }
        }
        if let violation = foldersViolation(bundle.folders, mode: mode) { return violation }
        let ids = bundle.allEntryIDs
        if Set(ids).count != ids.count { return .duplicateEntryID }
        return linkViolation(bundle)
    }

    // MARK: - Header fields

    private static func expiryViolation(_ bundle: ShareBundleModel) -> SharePackageViolation? {
        let lifetime = bundle.expiresAt.timeIntervalSince(bundle.createdAt)
        let longest = Timeouts.shareMaxExpiry.timeInterval + Timeouts.shareClockSkew.timeInterval
        return lifetime > 0 && lifetime <= longest ? nil : .invalidExpiry
    }

    private static func stagesViolation(_ stages: [String]) -> SharePackageViolation? {
        var keys = Set<String>()
        for stage in stages {
            if let error = EnvironmentNameValidator.violation(in: stage, requireNFC: true) {
                return .invalidStage(error)
            }
            guard keys.insert(EnvironmentNameValidator.foldKey(stage)).inserted else { return .duplicateStage }
        }
        return nil
    }

    // MARK: - Repositories

    private static func repositoryViolation(
        _ entry: ShareBundleRepositoryModel,
        mode: SharePackageValidator.Mode
    ) -> SharePackageViolation? {
        let repository = entry.repository
        if let violation = SharePackageValidator.repositoryViolation(repository) { return violation }
        if let violation = SharePackageValidator.itemsViolation(repository, mode: mode, allowsLink: true) {
            return violation
        }
        if let violation = SharePackageValidator.partialEnvironmentViolation(repository, allowsPartial: true) {
            return violation
        }
        if entry.destinations.count > Limits.maxDestinationsPerRepository {
            return .tooManyDestinations(limit: Limits.maxDestinationsPerRepository)
        }
        var targetKeys = Set<String>()
        for destination in entry.destinations {
            if let violation = destinationViolation(destination, mode: mode) { return violation }
            guard targetKeys.insert(destination.target.targetKey).inserted else { return .duplicateDestination }
        }
        return nil
    }

    // MARK: - Destinations

    private static func destinationViolation(
        _ destination: ShareDestinationModel,
        mode: SharePackageValidator.Mode
    ) -> SharePackageViolation? {
        do {
            // The trimmed form must already be the one written.
            guard try DestinationRules.validate(destination.target) == destination.target else {
                return .invalidDestinationTarget(.invalidDestinationTarget(.keyVaultName))
            }
        } catch {
            return .invalidDestinationTarget(error)
        }
        if let stage = destination.stage, let error = EnvironmentNameValidator.violation(in: stage, requireNFC: true) {
            return .invalidDestinationTarget(error)
        }
        if destination.itemCount > Limits.maxDestinationItems {
            return .tooManyDestinationItems(limit: Limits.maxDestinationItems)
        }
        let provider = destination.provider
        var nameKeys = Set<String>()
        for (items, kind) in [(destination.secrets, ConfigKind.secret), (destination.variables, .variable)] {
            for item in items {
                if let violation = SharePackageValidator.itemViolation(item, mode: mode, allowsLink: true) {
                    return violation
                }
                if let error = DestinationRules.violation(of: item.name, kind: kind, provider: provider) {
                    return .invalidDestinationItem(error)
                }
                if mode == .payload, let violation = destinationValueViolation(item, provider: provider) {
                    return violation
                }
                guard nameKeys.insert(GitHubNameValidator.foldKey(item.name)).inserted else {
                    return .duplicateDestinationItem
                }
            }
        }
        return nil
    }

    /// The provider's value size limit (Key Vault: 25 KiB).
    private static func destinationValueViolation(_ item: ShareItemModel, provider: DestinationProvider) -> SharePackageViolation? {
        let limit = DestinationRules.maxValueBytes(for: provider)
        guard SharePackageValidator.valueViolation(item, maxValueBytes: limit) == .valueTooLarge(limit: limit) else {
            return nil
        }
        return .invalidDestinationItem(.valueTooLarge(limit: limit))
    }

    // MARK: - Folders

    private static func foldersViolation(
        _ folders: [ShareBundleFolderModel],
        mode: SharePackageValidator.Mode
    ) -> SharePackageViolation? {
        var nameKeys = Set<String>()
        for folder in folders {
            if let error = FolderNameValidator.violation(in: folder.name, requireNFC: true) {
                return .invalidFolderName(error)
            }
            guard nameKeys.insert(FolderNameValidator.foldKey(folder.name)).inserted else { return .duplicateFolder }
            if folder.itemCount > Limits.maxFolderItems {
                return .tooManyFolderItems(limit: Limits.maxFolderItems)
            }
            for (items, kind) in [(folder.secrets, ConfigKind.secret), (folder.variables, .variable)] {
                var keys = Set<String>()
                for item in items {
                    // A folder item always has a value (schema 3).
                    guard item.valueState == .present else { return .valueStateMismatch }
                    if let violation = SharePackageValidator.itemViolation(item, mode: mode, allowsLink: true) {
                        return violation
                    }
                    guard keys.insert(GitHubNameValidator.foldKey(item.name)).inserted else {
                        return .duplicateItem(kind: kind, level: .repository)
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Links

    private static func linkViolation(_ bundle: ShareBundleModel) -> SharePackageViolation? {
        for (token, members) in bundle.linkGroups {
            let isWellFormed = UUID(uuidString: token) != nil && token == token.lowercased()
            guard isWellFormed, members.count >= 2 else { return .invalidLinkToken }
        }
        return nil
    }
}
