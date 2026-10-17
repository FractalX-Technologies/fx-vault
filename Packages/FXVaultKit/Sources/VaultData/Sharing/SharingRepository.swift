import EnvTools
import Foundation
import GitHubKit
import os
import SharingKit
import VaultCore
import VaultCrypto
import VaultStore

/// Sharing between teammates (§9; D21–D23, D30; M6): `.fxvault` files and the nearby
/// protocol, both ending in the same import.
///
/// **Export**: every `.fxvault` file is a schema 4 bundle in format 2 (v0.9.0). Project shares
/// are written by ``exportBundle(_:protection:to:senderName:appVersion:authorization:existingFile:)``
/// (`SharingRepository+ProjectShare.swift`); a package received in Nearby Chat by
/// ``exportFile(package:to:authorization:existingFile:)``. Both need a single-use
/// ``ShareAuthorizationModel`` (`ReauthGate.authorizeShare(.fileExport, …)`), write 0600 with
/// `SecureFileWriter` and return the passphrase once to show; every plaintext is wiped.
///
/// **Import** (``readFile(at:)`` → ``openFile(_:passphrase:checkGitHub:)`` →
/// ``apply(_:plan:confirmReplay:)``): the header is checked before a passphrase is asked for,
/// the package is decrypted and validated, then planned against the receiver's vault
/// (`ShareImportPlanner`: chips, merge defaults, replay warnings, policy differences) with a
/// keyed fingerprinter, optionally using GitHub's current listing. Apply re-plans inside the
/// write transaction and refuses (`.planOutdated`) if the preview changed, so the user's choices
/// always apply to what they reviewed. Nothing syncs automatically.
///
/// **Project shares** (v0.9.0, `SharingRepository+ProjectShare.swift`): several repositories with
/// their destinations and folders in one `.fxvault` format 2 file, sealed with a passphrase or for
/// teammates, opened through ``inspectFile(at:)`` and ``openShareFile(_:passphrase:checkGitHub:)``.
///
/// **Nearby** (``makeNearbySender(transport:localName:clock:)``,
/// ``makeNearbyReceiver(transport:localName:clock:)``): orchestration around `NearbySession`
/// that builds the manifest and payload on the sender and plans and applies them on the
/// receiver through the same importer.
public actor SharingRepository {
    let session: VaultSession
    let schedulers: (any GHSchedulerProviding)?
    private let codec: FxVaultFileCodec
    /// `.fxvault` format 2 (v0.9.0): project shares, passphrase or teammates.
    let fileCodec: FxVaultFileV2Codec
    let clock: any VaultClock
    let writePolicy: WriteCollaboratorPolicy
    let fileWriter: SecureFileWriter
    private let builder: ShareExportBuilder
    let projectBuilder: ProjectShareExportBuilder
    /// Whether a bundle's repository missing from the vault can be imported (nil: never checked).
    let repositoryAccess: (any ShareRepositoryAccessChecking)?
    private var passphraseGenerator: PassphraseGenerator?

    static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "sharing")

    /// - Parameters:
    ///   - schedulers: used to read GitHub's current state of the target repository while
    ///     planning an import (nil: plan from local state only).
    ///   - deriver: the `.fxvault` key derivation; tests inject a fast fake.
    ///   - repositoryAccess: checks and imports a project share's repositories that are not in
    ///     the vault (``CatalogShareRepositoryAccess`` in the app; nil: they are shown as not
    ///     checked).
    public init(
        session: VaultSession,
        schedulers: (any GHSchedulerProviding)? = nil,
        deriver: any KeyDeriving = Argon2idSharingDeriver(),
        clock: any VaultClock = SystemClock(),
        writePolicy: WriteCollaboratorPolicy = .default,
        fileWriter: SecureFileWriter = SecureFileWriter(),
        repositoryAccess: (any ShareRepositoryAccessChecking)? = nil
    ) {
        self.session = session
        self.schedulers = schedulers
        codec = FxVaultFileCodec(deriver: deriver)
        fileCodec = FxVaultFileV2Codec(deriver: deriver)
        self.clock = clock
        self.writePolicy = writePolicy
        self.fileWriter = fileWriter
        builder = ShareExportBuilder(session: session, clock: clock)
        projectBuilder = ProjectShareExportBuilder(session: session, clock: clock)
        self.repositoryAccess = repositoryAccess
    }

    // MARK: - Export (§9.1–§9.3)

    /// What exporting `selection` would contain (names and counts only; no values decrypted).
    public func previewExport(_ selection: ShareSelectionModel) throws(SharingError) -> ShareExportPreviewModel {
        let package = try builder.build(selection, senderName: "", appVersion: Self.previewVersion, includeValues: false)
        return ShareExportBuilder.preview(package)
    }

    /// Writes a package received in Nearby Chat to a `.fxvault` file (v0.4.0 "Save as File…";
    /// v0.9.0: a schema 4 bundle in format 2 under a fresh passphrase, expiring after
    /// ``ShareExpiryChoice/default``). It keeps the sender's package id (replay detection) and
    /// name; its date is the day it is saved. A package with a production environment is refused
    /// (`.productionNeedsTeammates`): production never travels under a passphrase (P3). Does not
    /// wipe `package`.
    ///
    /// - Parameter authorization: from `ReauthGate.authorizeShare(.fileExport, …)`; consumed here.
    /// - Throws: `.productionNeedsTeammates`, `.authorizationInvalid`, `.share`, `.write`.
    public func exportFile(
        package: SharePackageModel,
        to destination: URL,
        authorization: ShareAuthorizationModel,
        existingFile: SecureFileWriter.ExistingFilePolicy = .fail
    ) async throws(SharingError) -> ShareFileExportResultModel {
        if package.repository.environments.contains(where: { StageRisk.isProduction($0.name) }) {
            throw .productionNeedsTeammates
        }
        try authorization.consume(.fileExport, for: session)
        let bundle = ShareBundleModel(package: package, createdAt: clock.now, expiry: .default)
        let json: SecretBytes
        do {
            json = try ShareBundleCoder.encode(bundle)
        } catch {
            throw .share(error)
        }
        defer { json.wipe() }
        let passphrase = try passphrases().generate()
        let file: Data
        do {
            file = try await fileCodec.sealWithPassphrase(payload: json, passphrase: passphrase)
        } catch {
            passphrase.wipe()
            throw .share(error)
        }
        return try write(file, itemCount: package.itemCount, passphrase: passphrase, preview: ShareExportBuilder.preview(package), to: destination, existingFile: existingFile)
    }

    /// Writes `file` owner-only; wipes the passphrase on failure.
    private func write(
        _ file: Data,
        itemCount: Int,
        passphrase: SecretBytes,
        preview: ShareExportPreviewModel,
        to destination: URL,
        existingFile: SecureFileWriter.ExistingFilePolicy
    ) throws(SharingError) -> ShareFileExportResultModel {
        do {
            try fileWriter.write(file, to: destination, existingFile: existingFile)
        } catch {
            passphrase.wipe()
            throw .write(error)
        }
        Self.log.info("Exported a share file with \(itemCount, privacy: .public) items")
        return ShareFileExportResultModel(fileURL: destination, passphrase: passphrase, preview: preview)
    }

    // MARK: - Import (§9.1 reader order, §9.5)

    /// Reads a `.fxvault` file and checks its header (§9.1 steps 1–6) before any passphrase is
    /// asked for. Every failure is `.share(.invalidFile)` or `.fileUnreadable`.
    public nonisolated func readFile(at url: URL) throws(SharingError) -> ShareFileModel {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        guard let size else { throw .fileUnreadable }
        guard size <= Limits.maxShareFileBytes else { throw .share(.invalidFile) }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .uncached)
        } catch {
            throw .fileUnreadable
        }
        do {
            return ShareFileModel(data: data, header: try FxVaultFileCodec.inspect(data))
        } catch {
            throw .share(error)
        }
    }

    /// Decrypts the file with the typed passphrase (§9.2 normalization), validates the package
    /// and plans it against this vault (§9.5).
    ///
    /// - Parameter checkGitHub: read GitHub's current state of the repository (B3, B6–B9) so
    ///   environments and items GitHub already has are imported as synced.
    /// - Throws: `.share(.invalidPassphrase)`, `.share(.invalidFile)` (wrong passphrase or
    ///   damaged file), `.share(.invalidPackage)`, `.vault(.locked)`.
    public func openFile(
        _ file: ShareFileModel,
        passphrase: String,
        checkGitHub: Bool = true
    ) async throws(SharingError) -> ShareImportDraftModel {
        switch try await openFileContents(file, passphrase: passphrase, checkGitHub: checkGitHub) {
        case .repository(let draft):
            return draft
        case .folder(let draft):
            draft.discard()
            throw .share(.invalidPackage(.scopeMismatch(.folder)))
        }
    }

    /// Decrypts the file like ``openFile(_:passphrase:checkGitHub:)``, and also opens a copy of a
    /// folder (v0.7.0): a repository package comes back planned, a folder as a
    /// ``ShareFolderDraftModel`` for "Save as Folder" or "Import Into…".
    public func openFileContents(
        _ file: ShareFileModel,
        passphrase: String,
        checkGitHub: Bool = true
    ) async throws(SharingError) -> ShareOpenedFileModel {
        guard !session.isLocked else { throw .vault(.locked) }
        let normalized: SecretBytes
        do {
            normalized = try passphrases().normalize(passphrase)
        } catch {
            throw .wrap(error)
        }
        defer { normalized.wipe() }
        let package: SharePackageModel
        do {
            package = try await codec.open(file.data, passphrase: normalized)
        } catch {
            throw .share(error)
        }
        defer { package.wipeValues() }
        guard package.isFolder else {
            return .repository(try await draft(for: package, mode: .payload, checkGitHub: checkGitHub))
        }
        let wasImported = try importedPackageIDs().contains(package.packageID)
        return .folder(ShareFolderDraftModel(package: ShareImportPlanning.copyingValues(of: package), wasImported: wasImported))
    }

    /// "Save as Folder" for a copy of a folder opened from a file (``FolderRepository/save(_:as:conflicts:)``);
    /// closes the draft and wipes its values.
    @discardableResult
    public func saveFolder(
        _ draft: ShareFolderDraftModel,
        as target: FolderSaveTargetModel,
        conflicts: ItemCopyConflictPolicy
    ) throws(SharingError) -> FolderSaveResultModel {
        guard !draft.isClosed else { throw .draftClosed }
        let result: FolderSaveResultModel
        do {
            result = try FolderRepository(session: session, clock: clock).save(draft.package, as: target, conflicts: conflicts)
        } catch {
            throw .config(error)
        }
        try draft.close()
        return result
    }

    /// "Import Into…" for a copy of a folder opened from a file: plans its items for `scope` of
    /// `repositoryID` (the usual preview, then ``apply(_:plan:confirmReplay:)``). The values move
    /// are copied into the returned draft and this one is closed and wiped.
    public func importDraft(
        _ draft: ShareFolderDraftModel,
        into repositoryID: RepoID,
        scope: ConfigScope,
        checkGitHub: Bool = true
    ) async throws(SharingError) -> ShareImportDraftModel {
        guard !draft.isClosed else { throw .draftClosed }
        let planned = try FolderPackageTargeting.package(draft.package, into: repositoryID, scope: scope, vault: session)
        let imported = try await self.draft(for: planned, mode: .payload, checkGitHub: checkGitHub)
        try draft.close()
        return imported
    }

    /// Plans the draft's package again against the current vault, for example after the
    /// one-click import of its repository (`.importBlocked(.repositoryNotImported)`). The old
    /// draft is closed; use the returned one.
    public func replan(_ draft: ShareImportDraftModel, checkGitHub: Bool = true) async throws(SharingError) -> ShareImportDraftModel {
        guard !draft.isClosedForApply else { throw .draftClosed }
        let fresh = try await self.draft(for: draft.package, mode: draft.mode, checkGitHub: checkGitHub)
        try draft.close()
        draft.discard()
        return fresh
    }

    /// Applies the reviewed `plan` in one transaction (§9.5) and closes the draft.
    ///
    /// - Parameter confirmReplay: the user confirmed the replay warning (required when
    ///   `plan.requiresReplayConfirmation`).
    /// - Throws: `.importBlocked`, `.replayNotConfirmed`, `.planOutdated` (the vault changed
    ///   since the preview: preview again), `.draftClosed`, `.config` (capability, capacity),
    ///   `.vault(.locked)`.
    @discardableResult
    public func apply(
        _ draft: ShareImportDraftModel,
        plan: ShareImportPlanModel,
        confirmReplay: Bool
    ) throws(SharingError) -> ShareImportResultModel {
        guard !draft.isClosedForApply else { throw .draftClosed }
        guard draft.mode == .payload else { throw .share(.importActionNotAllowed) }
        guard plan.packageID == draft.plan.packageID else { throw .planOutdated }
        if let reason = plan.blockReason { throw .importBlocked(reason) }
        if plan.requiresReplayConfirmation, !confirmReplay { throw .replayNotConfirmed }
        do {
            try session.ensureCurrent(draft.generation)
        } catch {
            throw .planOutdated
        }
        let database = session.database
        let now = clock.now
        let writePolicy = writePolicy
        let result = try performSharing {
            try session.write { keys, tx in
                let keys = copy keys
                // Read inside the transaction: a package imported since the preview changes the
                // replay warnings, so the comparison below refuses with .planOutdated.
                let imported = try SharePackageStore(database: database).fetchAll(in: tx).map(\.packageID)
                let local = try ShareImportPlanning.localState(
                    for: draft.package.repository,
                    database: database,
                    tx: tx,
                    remote: draft.remote,
                    importedPackageIDs: Set(imported),
                    now: now
                )
                let fresh = try ShareImportPlanner.plan(
                    draft.package,
                    mode: .payload,
                    local: local,
                    fingerprint: ShareImportPlanning.fingerprinter(keys: keys, remote: draft.remote)
                )
                guard ShareImportPlanning.isSamePreview(fresh, as: plan) else { throw SharingError.planOutdated }
                return try ShareImporter(database: database, tx: tx, keys: keys, now: now, writePolicy: writePolicy)
                    .apply(plan, package: draft.package, remote: draft.remote)
            }
        }
        try draft.close()
        draft.discard()
        Self.log.info("Imported a share package: \(result.changedCount, privacy: .public) items changed")
        return result
    }

    // MARK: - Nearby (§9.4)

    /// The sender side of a nearby share over `transport` (an `NWNearbyTransport` the app
    /// connected, or an in-memory one in tests).
    public func makeNearbySender(
        transport: any NearbyTransport,
        localName: String,
        clock: (any VaultClock)? = nil
    ) -> NearbyShareSender {
        NearbyShareSender(
            session: NearbySession(
                role: .initiator,
                localName: DisplayNameSanitizer.sanitize(localName),
                transport: transport,
                clock: clock ?? self.clock
            ),
            vault: session,
            builder: builder
        )
    }

    /// The receiver side of a nearby share over `transport`.
    public func makeNearbyReceiver(
        transport: any NearbyTransport,
        localName: String,
        clock: (any VaultClock)? = nil
    ) -> NearbyShareReceiver {
        NearbyShareReceiver(
            session: NearbySession(
                role: .responder,
                localName: DisplayNameSanitizer.sanitize(localName),
                transport: transport,
                clock: clock ?? self.clock
            ),
            repository: self
        )
    }

    // MARK: - Planning

    /// Plans `package` (a decrypted file, or a nearby manifest or payload) against this vault.
    /// The draft owns a copy of the package's values; the caller still wipes its own.
    func draft(
        for package: SharePackageModel,
        mode: SharePackageValidator.Mode,
        checkGitHub: Bool
    ) async throws(SharingError) -> ShareImportDraftModel {
        let remote = checkGitHub ? await remoteContext(for: package.repository) : nil
        let imported = try importedPackageIDs()
        let generation = session.generation
        let database = session.database
        let now = clock.now
        let plan = try performSharing {
            try session.read { keys, tx in
                let local = try ShareImportPlanning.localState(
                    for: package.repository,
                    database: database,
                    tx: tx,
                    remote: remote,
                    importedPackageIDs: imported,
                    now: now
                )
                return try ShareImportPlanner.plan(
                    package,
                    mode: mode,
                    local: local,
                    fingerprint: ShareImportPlanning.fingerprinter(keys: copy keys, remote: remote)
                )
            }
        }
        return ShareImportDraftModel(
            plan: plan,
            package: ShareImportPlanning.copyingValues(of: package),
            mode: mode,
            remote: remote,
            generation: generation
        )
    }

    /// GitHub's current listing of the package's repository, when it is in the vault and on
    /// GitHub. Any failure leaves it out: the planner then treats GitHub's state as unknown.
    func remoteContext(
        for repository: ShareRepositoryModel,
        sharing rowIDs: [ShareRemoteKeyModel: ConfigItemID] = [:]
    ) async -> ShareRemoteContextModel? {
        guard let schedulers,
              let local = try? RepoStore(database: session.database).fetch(ownerLogin: repository.owner, name: repository.name),
              local.existsOnGitHub,
              let ref = try? GHRepoRef(owner: local.ownerLogin, name: local.name)
        else { return nil }
        do {
            let scheduler = try await schedulers.scheduler(for: local.accountLogin)
            let listed = try await RemoteConfigReader(scheduler: scheduler, repo: ref).read()
            defer { listed.wipe() }
            return try session.withKeys { ShareImportPlanning.remoteContext(listed, keys: $0, sharing: rowIDs) }
        } catch {
            Self.log.error("GitHub listing for a share import failed; planning from local state")
            return nil
        }
    }

    func importedPackageIDs() throws(SharingError) -> Set<SharePackageID> {
        Set(try performSharing { try SharePackageStore(database: session.database).fetchAll() }.map(\.packageID))
    }

    func passphrases() throws(SharingError) -> PassphraseGenerator {
        if let passphraseGenerator { return passphraseGenerator }
        do {
            let generator = try PassphraseGenerator.bundled()
            passphraseGenerator = generator
            return generator
        } catch {
            throw .share(error)
        }
    }

    /// `producer.version` of a preview package, which is never sent.
    private static let previewVersion = "0"
}

// MARK: - Testing

@_spi(Testing)
extension SharingRepository {
    /// Writes `selection` as FX Vault 0.8 did: `.fxvault` format 1, a schema 1–3 package, no
    /// expiry. The app never writes one; tests use it to check that files from older versions
    /// still open (scripts/lint.sh keeps `@_spi(Testing)` imports out of App/).
    ///
    /// - Throws: `.authorizationInvalid`, `.nothingToShare`, `.share`, `.write`, `.vault(.locked)`.
    public func exportLegacyFile(
        _ selection: ShareSelectionModel,
        to destination: URL,
        senderName: String,
        appVersion: String,
        authorization: ShareAuthorizationModel,
        existingFile: SecureFileWriter.ExistingFilePolicy = .fail
    ) async throws(SharingError) -> ShareFileExportResultModel {
        try authorization.consume(.fileExport, for: session)
        let package = try builder.build(selection, senderName: senderName, appVersion: appVersion, includeValues: true)
        defer { package.wipeValues() }
        let passphrase = try passphrases().generate()
        let file: Data
        do {
            file = try await codec.seal(package, passphrase: passphrase)
        } catch {
            passphrase.wipe()
            throw .share(error)
        }
        return try write(file, itemCount: package.itemCount, passphrase: passphrase, preview: ShareExportBuilder.preview(package), to: destination, existingFile: existingFile)
    }
}
