import CoreServices
import EnvTools
import Foundation
import os
import VaultCore
import VaultCrypto
import VaultStore

/// Files kept in folders (v23): any file up to ``Limits/maxFolderFileBytes``, sealed as one blob
/// with ``FolderFileAAD`` (row and DEK version only, so a rename re-seals nothing). The bytes leave
/// the vault only through ``saveFile(_:to:authorization:)``, after a fresh re-authentication.
/// Files stay out of everything that handles values (notes, copies, `.env`, shares).
extension FolderRepository {
    /// Reads `url` and keeps it in `folderID`. A name the folder already has becomes
    /// `name 2.ext` (Finder's pattern), so adding the same file twice keeps both.
    ///
    /// - Throws: `.tooLarge`, `.unreadable` (a folder, a pipe, a file that changes while read),
    ///   `.config(.folderNotFound)`, `.config(.validation(.invalidName(_)))` for a name Save As…
    ///   could not use, `.config(.vault(.locked))`.
    @discardableResult
    public func addFile(from url: URL, to folderID: FolderID) throws(FolderFileError) -> FolderFileModel {
        let name: String
        do {
            name = try FolderFileNameValidator.validated(url.lastPathComponent)
        } catch {
            throw .config(.validation(error))
        }
        let contents: SecretBytes
        do {
            contents = try SecretFileReader.read(url, maxBytes: Limits.maxFolderFileBytes)
        } catch .tooLarge {
            throw .tooLarge(limit: Limits.maxFolderFileBytes)
        } catch {
            throw .unreadable
        }
        defer { contents.wipe() }
        do {
            let file = try write { keys, tx, now in
                guard try store.fetchFolder(id: folderID, in: tx) != nil else { throw ConfigRepositoryError.folderNotFound }
                let taken = Set(try store.fetchFileRecords(folderID: folderID, in: tx).map(\.nameKey))
                let record = FolderFileRecord(
                    folderID: folderID,
                    name: FolderFileNameValidator.available(name, taken: taken),
                    byteCount: contents.count,
                    createdAt: now,
                    updatedAt: now
                )
                let sealed = try keys.seal(contents, for: FolderFileAAD(fileID: record.id))
                try store.insertFile(record, blob: FolderFileBlobRecord(fileID: record.id, contentCiphertext: sealed), in: tx)
                return record.model
            }
            Self.log.info("Added a folder file of \(contents.count, privacy: .public) bytes")
            return file
        } catch {
            throw .config(error)
        }
    }

    /// The files of one folder by name.
    public func files(folderID: FolderID) throws(ConfigRepositoryError) -> [FolderFileModel] {
        try performConfig {
            try session.database.read { tx in try store.fetchFileRecords(folderID: folderID, in: tx).map(\.model) }
        }
    }

    /// The files of one folder, now and after each change. Needs no keys.
    public func observeFiles(folderID: FolderID) -> AsyncThrowingStream<[FolderFileModel], any Error> {
        store.observeFiles(folderID: folderID)
    }

    /// Renames a file; the bytes are not re-sealed (the name is not in their AAD).
    ///
    /// - Throws: `.validation(.invalidName)`, `.validation(.duplicateName)` for a name another
    ///   file of the folder has, `.itemNotFound`, `.vault(.locked)`.
    public func renameFile(_ id: FolderFileID, to name: String) throws(ConfigRepositoryError) {
        let name = try performConfig { try FolderFileNameValidator.validated(name) }
        try write { _, tx, now in
            guard var record = try store.fetchFileRecord(id: id, in: tx) else { throw ConfigRepositoryError.itemNotFound }
            let key = FolderNameValidator.foldKey(name)
            let others = try store.fetchFileRecords(folderID: record.folderID, in: tx).filter { $0.id != id }
            guard !others.contains(where: { $0.nameKey == key }) else { throw ValidationError.duplicateName }
            record.name = name
            record.nameKey = key
            record.updatedAt = now
            try store.updateFile(record, in: tx)
        }
    }

    /// Deletes files and their bytes in one transaction.
    public func deleteFiles(_ ids: [FolderFileID]) throws(ConfigRepositoryError) {
        try write { _, tx, _ in
            for id in ids {
                try store.deleteFile(id: id, in: tx)
            }
        }
        Self.log.info("Deleted \(ids.count, privacy: .public) folder files")
    }

    /// Writes a file's bytes to `url` (mode 0600, replacing what Save As… confirmed), marks it as
    /// downloaded, and consumes `authorization`.
    ///
    /// - Throws: `.authorizationInvalid`, `.config(.itemNotFound)`, `.config(.vault(_))`, `.write`,
    ///   `.quarantine`.
    public func saveFile(
        _ id: FolderFileID,
        to url: URL,
        authorization: FolderFileSaveAuthorizationModel,
        writer: SecureFileWriter = SecureFileWriter()
    ) throws(FolderFileError) {
        try authorization.consume(for: session)
        let contents: SecretBytes
        do {
            contents = try performConfig {
                try session.read { keys, tx in
                    guard let blob = try store.fetchFileBlob(fileID: id, in: tx) else { throw ConfigRepositoryError.itemNotFound }
                    return try keys.open(blob.contentCiphertext, for: FolderFileAAD(fileID: id))
                }
            }
        } catch {
            throw .config(error)
        }
        defer { contents.wipe() }
        do {
            try writer.write(contents, to: url, existingFile: .replace)
        } catch {
            throw .write(error)
        }
        try Self.quarantine(url)
        Self.log.info("Saved a folder file of \(contents.count, privacy: .public) bytes")
    }

    /// FX Vault is not sandboxed, so macOS does not quarantine what it writes, and the inode
    /// Save As… creates never carries the original's quarantine: without this, an app or script
    /// kept in the vault would open after Save As… with no Gatekeeper check. A file that cannot
    /// be marked is removed.
    static func quarantine(_ url: URL) throws(FolderFileError) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "FX Vault",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        var marked = url
        do {
            try marked.setResourceValues(values)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw .quarantine
        }
    }
}
