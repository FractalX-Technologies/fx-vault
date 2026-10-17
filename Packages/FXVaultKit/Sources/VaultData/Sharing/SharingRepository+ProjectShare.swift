import EnvTools
import Foundation
import os
import SharingKit
import VaultCore
import VaultStore

/// Project shares (v0.9.0, tasks/todo.md P1–P10): several repositories with their GitHub scopes,
/// runtime destinations and optional folders in one `.fxvault` format 2 file (share schema 4).
///
/// **Export** (``exportBundle(_:protection:to:senderName:appVersion:authorization:existingFile:)``):
/// the selection is checked first (recipients; a production stage refuses a passphrase, Q13),
/// then the single-use `.fileExport` authorization is consumed, values are decrypted inside
/// `VaultSession.read`, and the bundle is sealed under a fresh 6-word passphrase or for 1–10
/// paired teammates (HPKE wraps, signed by this Mac). A `sent_shares` row (names only) is written
/// before the 0600 file; a failed write removes it again.
///
/// **Import** (``inspectFile(at:)`` → ``openShareFile(_:passphrase:checkGitHub:)`` →
/// ``importMissingRepositories(of:)`` → ``applyBundle(_:plan:confirmReplay:)``): the header is
/// checked before any passphrase or key is used; a teammates file must be addressed to this Mac
/// and signed by a paired teammate, whose announce key is stored when this Mac had none. Schema
/// 1–3 documents keep today's flow; a bundle is checked for expiry, planned per repository
/// (✓ in the vault, ⇣ importable, ✕ skipped) and applied in one transaction that re-plans first
/// (`.planOutdated` when the preview changed). Rows the remote does not have yet are held for
/// Sync's From Files review (P8).
extension SharingRepository {
    // MARK: - Export: stages and selection

    /// The stages of `repositoryIDs` for the share sheet (environment names and destination
    /// stages, production ones flagged).
    public func stageOptions(repositoryIDs: [RepoID]) throws(SharingError) -> [ShareStageOptionModel] {
        try projectBuilder.stageOptions(repositoryIDs: repositoryIDs)
    }

    /// A selection of `repositoryIDs` expanded from `stages`: per repository the environment
    /// named like each stage and that stage's destinations, plus the repository level when asked
    /// for. Adjust it per repository before exporting.
    public func selection(
        repositoryIDs: [RepoID],
        stages: [String],
        includesRepositoryLevel: Bool = true,
        folderIDs: [FolderID] = [],
        expiry: ShareExpiryChoice = .default
    ) throws(SharingError) -> ShareBundleSelectionModel {
        try projectBuilder.selection(
            repositoryIDs: repositoryIDs,
            stages: stages,
            includesRepositoryLevel: includesRepositoryLevel,
            folderIDs: folderIDs,
            expiry: expiry
        )
    }

    /// What exporting `selection` would contain (names and counts only; no values decrypted).
    public func previewBundle(_ selection: ShareBundleSelectionModel) throws(SharingError) -> ShareBundleExportPreviewModel {
        ProjectShareExportBuilder.preview(
            try projectBuilder.build(selection, senderName: "", appVersion: Self.bundlePreviewVersion, includeValues: false)
        )
    }

    /// The name a new share file gets (P5): no repository or stage, which chats and mail show to
    /// everyone. `FX Vault share 2026-10-17.fxvault`.
    public nonisolated func defaultFileName(timeZone: TimeZone = .current) -> String {
        Self.defaultFileName(createdAt: clock.now, timeZone: timeZone)
    }

    /// ``defaultFileName(timeZone:)`` for a given date.
    public static func defaultFileName(createdAt: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: createdAt)
        let date = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return "\(fileNamePrefix) \(date).\(fileExtension)"
    }

    /// The share file extension.
    public static let fileExtension = "fxvault"
    private static let fileNamePrefix = "FX Vault share"
    /// `producer.version` of a preview bundle, which is never sent.
    private static let bundlePreviewVersion = "0"

    // MARK: - Export: the file

    /// Writes `selection` to a new `.fxvault` format 2 file at `destination` (mode 0600).
    ///
    /// - Parameters:
    ///   - protection: a fresh passphrase (refused for a selection with a production stage), or
    ///     the teammates (by id) to seal it for.
    ///   - senderName: shown to the receiver of a passphrase file as an unverified name; a
    ///     teammate sees this Mac's stored name instead.
    ///   - authorization: from `ReauthGate.authorizeShare(.fileExport, …)`; consumed here, after
    ///     the selection and recipients were checked.
    /// - Throws: `.productionNeedsTeammates`, `.invalidRecipients`, `.authorizationInvalid`,
    ///   `.nothingToShare`, `.share`, `.team`, `.write`, `.vault(.locked)`.
    public func exportBundle(
        _ selection: ShareBundleSelectionModel,
        protection: ShareBundleProtectionModel,
        to destination: URL,
        senderName: String,
        appVersion: String,
        authorization: ShareAuthorizationModel,
        existingFile: SecureFileWriter.ExistingFilePolicy = .fail
    ) async throws(SharingError) -> ShareBundleExportResultModel {
        let checked = try projectBuilder.build(selection, senderName: senderName, appVersion: appVersion, includeValues: false)
        if case .passphrase = protection, !checked.productionPlaces.isEmpty {
            throw .productionNeedsTeammates
        }
        let recipients = try recipientKeys(for: protection)
        try authorization.consume(.fileExport, for: session)
        let built = try projectBuilder.build(selection, senderName: senderName, appVersion: appVersion, includeValues: true)
        defer { built.bundle.wipeValues() }
        // Checked again on what is sealed: an environment renamed since the first read counts.
        if recipients == nil, !built.productionPlaces.isEmpty {
            throw .productionNeedsTeammates
        }
        let json: SecretBytes
        do {
            json = try ShareBundleCoder.encode(built.bundle)
        } catch {
            throw .share(error)
        }
        defer { json.wipe() }

        let passphrase = recipients == nil ? try passphrases().generate() : nil
        let file: Data
        do throws(ShareError) {
            if let recipients {
                file = try fileCodec.sealForTeammates(payload: json, sender: recipients.device, recipients: recipients.teammates)
            } else if let passphrase {
                file = try await fileCodec.sealWithPassphrase(payload: json, passphrase: passphrase)
            } else {
                throw ShareError.encryptionFailed
            }
        } catch {
            passphrase?.wipe()
            throw .share(error)
        }

        let sent = SentShareModel(
            packageID: built.bundle.packageID,
            createdAt: built.bundle.createdAt,
            expiresAt: built.bundle.expiresAt,
            mode: protection.mode,
            recipientIDs: recipients?.teammates.map(\.deviceID.hex) ?? [],
            summary: built.sentSummary
        )
        let sentLog = SentShareStore(database: session.database)
        do {
            try sentLog.insert(sent)
        } catch {
            passphrase?.wipe()
            throw .wrap(error)
        }
        do {
            try fileWriter.write(file, to: destination, existingFile: existingFile)
        } catch {
            passphrase?.wipe()
            _ = try? sentLog.delete(id: sent.id)
            throw .write(error)
        }
        Self.log.info(
            "Exported a project share: \(built.bundle.repositories.count, privacy: .public) repositories, \(built.bundle.itemCount, privacy: .public) items"
        )
        return ShareBundleExportResultModel(
            fileURL: destination,
            passphrase: passphrase,
            preview: ProjectShareExportBuilder.preview(built),
            sentShare: sent
        )
    }

    /// The share files this Mac wrote, newest first (Settings › Sharing). Names only.
    public func sentShares() throws(SharingError) -> [SentShareModel] {
        try performSharing { try SentShareStore(database: session.database).fetchAll() }
    }

    /// The sent log, now and after each change.
    public nonisolated func observeSentShares() -> AsyncThrowingStream<[SentShareModel], any Error> {
        SentShareStore(database: session.database).observe()
    }

    /// Removes one entry of the sent log (the file itself is out of reach).
    public func deleteSentShare(_ id: SentShareID) throws(SharingError) {
        _ = try performSharing { try SentShareStore(database: session.database).delete(id: id) }
    }

    /// This Mac's keys and the chosen teammates' keys for a teammates file; nil for a passphrase.
    private func recipientKeys(for protection: ShareBundleProtectionModel) throws(SharingError) -> ProjectShareRecipients? {
        guard case .teammates(let ids) = protection else { return nil }
        guard (1...Limits.maxShareRecipients).contains(ids.count), Set(ids).count == ids.count else {
            throw .invalidRecipients
        }
        let team = TeamRepository(session: session, clock: clock)
        let cards = try performSharing { try team.teammateCards() }
        let byID = Dictionary(cards.map { ($0.deviceID.hex, $0) }, uniquingKeysWith: { first, _ in first })
        let teammates = try ids.map { id throws(SharingError) -> ShareTeammateKeyModel in
            guard let card = byID[id.lowercased()] else { throw .invalidRecipients }
            return ShareTeammateKeyModel(card: card)
        }
        let device = try performSharing { try team.deviceKeys() }
        guard !teammates.contains(where: { $0.deviceID == device.deviceID }) else { throw .invalidRecipients }
        return ProjectShareRecipients(device: device, teammates: teammates)
    }

    // MARK: - Import: reading and opening

    /// Reads a share file and checks its header (formats 1 and 2) before any passphrase or key is
    /// used. Every failure is `.share(.invalidFile)` or `.fileUnreadable`.
    public nonisolated func inspectFile(at url: URL) throws(SharingError) -> ShareInspectedFileModel {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        guard let size else { throw .fileUnreadable }
        guard size <= Limits.maxShareFileV2Bytes else { throw .share(.invalidFile) }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .uncached)
        } catch {
            throw .fileUnreadable
        }
        do {
            return ShareInspectedFileModel(data: data, info: try FxVaultFileV2Codec.inspect(data))
        } catch {
            throw .share(error)
        }
    }

    /// Opens an inspected file: with the typed passphrase, or as one of its teammates. A
    /// teammates file delivers the sender's announce key when this Mac had none for it (a
    /// remote pairing, v0.9.0). Schema 1–3 contents are planned as before; a bundle is checked for
    /// expiry and planned per repository.
    ///
    /// - Parameter checkGitHub: read GitHub's current state of the repositories in the vault, so
    ///   items GitHub already has are imported as synced.
    /// - Throws: `.share(.invalidPassphrase)`, `.share(.invalidFile)`, `.share(.notARecipient)`,
    ///   `.share(.senderNotTeammate)`, `.share(.expired)`, `.share(.invalidPackage)`, `.team`,
    ///   `.vault(.locked)`.
    public func openShareFile(
        _ file: ShareInspectedFileModel,
        passphrase: String?,
        checkGitHub: Bool = true
    ) async throws(SharingError) -> ShareOpenedShareFileModel {
        guard !session.isLocked else { throw .vault(.locked) }
        let opened = try await decrypt(file, passphrase: passphrase)
        defer { opened.json.wipe() }
        let document: ShareDocumentModel
        do {
            document = try ShareDocumentCoder.open(opened.json, mode: .payload)
        } catch {
            throw .share(error)
        }
        defer { document.wipeValues() }
        switch document {
        case .package(let package):
            let sender = opened.verifiedSender ?? ShareFileSenderModel(displayName: package.sender.displayName, isVerified: false)
            guard package.isFolder else {
                let draft = try await draft(for: package, mode: .payload, checkGitHub: checkGitHub)
                return ShareOpenedShareFileModel(document: .repository(draft), sender: sender)
            }
            let wasImported = try importedPackageIDs().contains(package.packageID)
            let folder = ShareFolderDraftModel(package: ShareImportPlanning.copyingValues(of: package), wasImported: wasImported)
            return ShareOpenedShareFileModel(document: .folder(folder), sender: sender)
        case .bundle(let bundle):
            let sender = opened.verifiedSender ?? ShareFileSenderModel(displayName: bundle.sender.displayName, isVerified: false)
            do {
                try bundle.checkFreshness(now: clock.now)
            } catch {
                throw .share(error)
            }
            let draft = try await bundleDraft(for: bundle, sender: sender, checkGitHub: checkGitHub)
            return ShareOpenedShareFileModel(document: .bundle(draft), sender: sender)
        }
    }

    /// The plaintext of `file` and, for a teammates file, its verified sender.
    private func decrypt(
        _ file: ShareInspectedFileModel,
        passphrase: String?
    ) async throws(SharingError) -> (json: SecretBytes, verifiedSender: ShareFileSenderModel?) {
        if file.needsPassphrase {
            let normalized: SecretBytes
            do {
                normalized = try passphrases().normalize(passphrase ?? "")
            } catch {
                throw .wrap(error)
            }
            defer { normalized.wipe() }
            do {
                return (try await fileCodec.openWithPassphrase(file.data, passphrase: normalized), nil)
            } catch {
                throw .share(error)
            }
        }
        let team = TeamRepository(session: session, clock: clock)
        let device = try performSharing { try team.deviceKeys() }
        let cards = try performSharing { try team.teammateCards() }
        let opened: FxVaultTeammateFileModel
        do {
            opened = try fileCodec.openAsTeammate(file.data, device: device, teammates: cards.map(ShareTeammateKeyModel.init(card:)))
        } catch {
            throw .share(error)
        }
        let senderID = opened.sender.hex
        do {
            try team.fillAnnounceKeyIfMissing(opened.senderAnnounceKey, teammate: senderID)
            let name = try team.teammates().first { $0.id == senderID }?.name ?? ""
            return (opened.payload, ShareFileSenderModel(displayName: name, isVerified: true, teammateID: senderID))
        } catch {
            opened.payload.wipe()
            throw .team(error)
        }
    }

    // MARK: - Import: planning

    /// Plans `bundle` against this vault. The draft owns a copy of the values; the caller still
    /// wipes its own.
    func bundleDraft(
        for bundle: ShareBundleModel,
        sender: ShareFileSenderModel,
        checkGitHub: Bool
    ) async throws(SharingError) -> ShareBundleDraftModel {
        var remotes: [String: ShareRemoteContextModel] = [:]
        var rowIDs: [ShareRemoteKeyModel: ConfigItemID] = [:]
        var access: [String: ShareRepositoryAccess] = [:]
        let repositories = RepoStore(database: session.database)
        for entry in bundle.repositories {
            let local = try performSharing { try repositories.fetch(ownerLogin: entry.repository.owner, name: entry.repository.name) }
            if local != nil {
                if checkGitHub, let remote = await remoteContext(for: entry.repository, sharing: rowIDs) {
                    remotes[entry.id] = remote
                    rowIDs = remote.rowIDs
                }
            } else {
                access[entry.id] = await repositoryAccess?.access(owner: entry.repository.owner, name: entry.repository.name) ?? .unknown
            }
        }
        let imported = try importedPackageIDs()
        let generation = session.generation
        let database = session.database
        let now = clock.now
        let sharedRowIDs = rowIDs
        let plan = try performSharing {
            try session.read { keys, tx in
                let local = try ProjectSharePlanning.localState(
                    for: bundle,
                    database: database,
                    tx: tx,
                    remotes: remotes,
                    access: access,
                    importedPackageIDs: imported,
                    now: now
                )
                return try ShareBundlePlanner.plan(
                    bundle,
                    mode: .payload,
                    local: local,
                    fingerprint: ShareImportPlanning.fingerprinter(keys: copy keys, rowIDs: sharedRowIDs),
                    destinationFingerprint: ProjectSharePlanning.destinationFingerprinter(keys: copy keys)
                )
            }
        }
        return ShareBundleDraftModel(
            plan: plan,
            bundle: ProjectSharePlanning.copyingValues(of: bundle),
            sender: sender,
            remotes: remotes,
            remoteRowIDs: sharedRowIDs,
            access: access,
            generation: generation
        )
    }

    /// Plans the draft's bundle again against the current vault (after a one-click import, or a
    /// `.planOutdated`). The old draft is closed; use the returned one.
    public func replanBundle(_ draft: ShareBundleDraftModel, checkGitHub: Bool = true) async throws(SharingError) -> ShareBundleDraftModel {
        guard !draft.isClosedForApply else { throw .draftClosed }
        let fresh = try await bundleDraft(for: draft.bundle, sender: draft.sender, checkGitHub: checkGitHub)
        try draft.close()
        draft.discard()
        return fresh
    }

    /// Imports every ⇣ repository of the draft from GitHub (outside any transaction, as the
    /// one-click import), then plans the bundle again. A failed import is reported and leaves
    /// that repository out of this import.
    public func importMissingRepositories(of draft: ShareBundleDraftModel) async throws(SharingError) -> ShareBundleRepositoryImportModel {
        guard !draft.isClosedForApply else { throw .draftClosed }
        var failed: [String] = []
        if let repositoryAccess {
            for repository in draft.plan.repositoriesToImport {
                guard case .willImportFromGitHub(let login) = repository.status else { continue }
                do {
                    _ = try await repositoryAccess.importRepository(owner: repository.owner, name: repository.name, accountLogin: login)
                } catch {
                    Self.log.error("Importing a repository of a project share failed")
                    failed.append(repository.fullName)
                }
            }
        } else {
            failed = draft.plan.repositoriesToImport.map(\.fullName)
        }
        return ShareBundleRepositoryImportModel(draft: try await replanBundle(draft), failedRepositories: failed)
    }

    // MARK: - Import: apply

    /// Applies the reviewed `plan` in one transaction (P7–P9) and closes the draft.
    ///
    /// - Parameter confirmReplay: the user confirmed the replay warning (required when
    ///   `plan.requiresReplayConfirmation`).
    /// - Throws: `.replayNotConfirmed`, `.planOutdated` (the vault changed since the preview: plan
    ///   again), `.draftClosed`, `.share(.expired)`, `.config`, `.validation`, `.vault(.locked)`.
    @discardableResult
    public func applyBundle(
        _ draft: ShareBundleDraftModel,
        plan: ShareBundlePlanModel,
        confirmReplay: Bool
    ) throws(SharingError) -> ShareBundleImportResultModel {
        guard !draft.isClosedForApply else { throw .draftClosed }
        guard plan.packageID == draft.plan.packageID else { throw .planOutdated }
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
                // Read inside the transaction, so a package imported since the preview changes the
                // replay warnings and the comparison below refuses with .planOutdated.
                let imported = try SharePackageStore(database: database).fetchAll(in: tx).map(\.packageID)
                let local = try ProjectSharePlanning.localState(
                    for: draft.bundle,
                    database: database,
                    tx: tx,
                    remotes: draft.remotes,
                    access: draft.access,
                    importedPackageIDs: Set(imported),
                    now: now
                )
                let fresh = try ShareBundlePlanner.plan(
                    draft.bundle,
                    mode: .payload,
                    local: local,
                    fingerprint: ShareImportPlanning.fingerprinter(keys: keys, rowIDs: draft.remoteRowIDs),
                    destinationFingerprint: ProjectSharePlanning.destinationFingerprinter(keys: keys)
                )
                guard fresh.isSamePreview(as: plan) else { throw SharingError.planOutdated }
                return try ProjectShareImporter(database: database, tx: tx, keys: keys, now: now, writePolicy: writePolicy)
                    .apply(plan, bundle: draft.bundle, remotes: draft.remotes, sender: draft.sender)
            }
        }
        try draft.close()
        draft.discard()
        Self.log.info(
            "Imported a project share: \(result.changedCount, privacy: .public) rows changed, \(result.heldCount, privacy: .public) held"
        )
        return result
    }
}

/// The keys that seal a teammates file.
struct ProjectShareRecipients {
    let device: TeamDeviceKeys
    let teammates: [ShareTeammateKeyModel]
}
