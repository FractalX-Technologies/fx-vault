import CoreServices
import EnvTools
import Foundation
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Folder files (v23, folder files and subfolders slice 3): any file up to 50 MB sealed in the
/// vault, saved back only with a fresh single-use authorization, renamed without re-sealing,
/// re-sealed by a DEK rotation, and gone with their folder.
@Suite("FolderRepository files")
struct FolderFileRepositoryTests {
    struct Fixture {
        let harness: ConfigHarness
        let folders: FolderRepository
        let directory: ConfigTempDirectory

        static func make() async throws -> Fixture {
            let harness = try await ConfigHarness.make()
            return Fixture(
                harness: harness,
                folders: FolderRepository(session: harness.session, clock: harness.clock),
                directory: try ConfigTempDirectory()
            )
        }

        var store: FolderStore {
            FolderStore(database: harness.database)
        }

        /// A file on disk with `bytes`, for Add File.
        func source(_ name: String, _ bytes: Data) throws -> URL {
            let url = directory.file("in-\(UUID().uuidString)").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            return url
        }

        func authorization() async throws -> FolderFileSaveAuthorizationModel {
            try await ReauthGate(manager: harness.manager).authorizeFileSave(
                with: .password(ConfigFixture.password),
                session: harness.session
            )
        }

        /// Saves the file to a new path and returns what was written.
        func saved(_ id: FolderFileID) async throws -> Data {
            let url = directory.file("out-\(UUID().uuidString)")
            try folders.saveFile(id, to: url, authorization: try await authorization())
            return try Data(contentsOf: url)
        }

        func blob(_ id: FolderFileID) throws -> Data {
            try harness.database.read { tx in try #require(try store.fetchFileBlob(fileID: id, in: tx)).contentCiphertext }
        }
    }

    static let pdf = Data("%PDF-1.7 synthetic test file\n".utf8) + Data((0..<4096).map { UInt8($0 % 251) })

    @Test func aFileIsSealedAndSavedBackByteForByte() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let folder = try fixture.folders.createFolder(named: "Mobile")

        let file = try fixture.folders.addFile(from: try fixture.source("Profile.pdf", Self.pdf), to: folder)

        #expect(file.name == "Profile.pdf")
        #expect(file.byteCount == Self.pdf.count)
        #expect(try fixture.folders.files(folderID: folder) == [file])
        #expect(try fixture.folders.folders().first?.fileCount == 1)
        // Only ciphertext is stored: the PDF header is nowhere in the blob.
        let blob = try fixture.blob(file.id)
        #expect(blob.range(of: Data("%PDF".utf8)) == nil)
        #expect(try await fixture.saved(file.id) == Self.pdf)
    }

    @Test func aSavedFileIsQuarantinedSoGatekeeperChecksIt() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let folder = try fixture.folders.createFolder(named: "Tools")
        let file = try fixture.folders.addFile(from: try fixture.source("install.command", Data("#!/bin/sh\n".utf8)), to: folder)
        let url = fixture.directory.file("install.command")

        try fixture.folders.saveFile(file.id, to: url, authorization: try await fixture.authorization())

        let quarantine = try #require(try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        #expect(quarantine[kLSQuarantineAgentNameKey as String] as? String == "FX Vault")
        #expect(quarantine[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeOtherDownload as String)
    }

    @Test func savingNeedsAFreshAuthorizationEachTime() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let folder = try fixture.folders.createFolder(named: "Mobile")
        let file = try fixture.folders.addFile(from: try fixture.source("key.p8", Self.pdf), to: folder)
        let authorization = try await fixture.authorization()
        try fixture.folders.saveFile(file.id, to: fixture.directory.file("a"), authorization: authorization)

        #expect(fileError { try fixture.folders.saveFile(file.id, to: fixture.directory.file("b"), authorization: authorization) }
            == .authorizationInvalid)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.file("b").path))

        // A lock in between invalidates an authorization that was never used.
        let unused = try await fixture.authorization()
        fixture.harness.manager.lock()
        #expect(fileError { try fixture.folders.saveFile(file.id, to: fixture.directory.file("c"), authorization: unused) }
            == .authorizationInvalid)
    }

    @Test func theSameNameTwiceKeepsBothLikeFinder() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let folder = try fixture.folders.createFolder(named: "Mobile")
        let other = try fixture.folders.createFolder(named: "Web")
        let url = try fixture.source("Build.ipa", Self.pdf)

        try fixture.folders.addFile(from: url, to: folder)
        try fixture.folders.addFile(from: url, to: folder)
        try fixture.folders.addFile(from: try fixture.source("build.IPA", Self.pdf), to: folder)
        try fixture.folders.addFile(from: url, to: other)

        #expect(try fixture.folders.files(folderID: folder).map(\.name) == ["Build 2.ipa", "build 3.IPA", "Build.ipa"])
        #expect(try fixture.folders.files(folderID: other).map(\.name) == ["Build.ipa"])
    }

    @Test func aFileOver50MBOrNotAFileIsRefused() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let folder = try fixture.folders.createFolder(named: "Mobile")
        let big = try fixture.source("big.zip", Data())
        // Sparse: the size check runs before anything is read.
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(Limits.maxFolderFileBytes + 1))
        try handle.close()

        #expect(fileError { try fixture.folders.addFile(from: big, to: folder) } == .tooLarge(limit: Limits.maxFolderFileBytes))
        #expect(fileError { try fixture.folders.addFile(from: fixture.directory.url, to: folder) } == .unreadable)
        #expect(try fixture.folders.files(folderID: folder).isEmpty)

        let exact = try fixture.source("exact.bin", Data())
        let exactHandle = try FileHandle(forWritingTo: exact)
        try exactHandle.truncate(atOffset: UInt64(Limits.maxFolderFileBytes))
        try exactHandle.close()
        #expect(try fixture.folders.addFile(from: exact, to: folder).byteCount == Limits.maxFolderFileBytes)
    }

    @Test func renamingKeepsTheSealedBytesAndChecksTheFolder() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let folder = try fixture.folders.createFolder(named: "Mobile")
        let first = try fixture.folders.addFile(from: try fixture.source("a.pdf", Self.pdf), to: folder)
        let second = try fixture.folders.addFile(from: try fixture.source("b.pdf", Data("b".utf8)), to: folder)
        let before = try fixture.blob(first.id)

        try fixture.folders.renameFile(first.id, to: "  Testflight Profile.pdf ")

        #expect(try fixture.folders.files(folderID: folder).map(\.name) == ["b.pdf", "Testflight Profile.pdf"])
        #expect(try fixture.blob(first.id) == before)
        #expect(try await fixture.saved(first.id) == Self.pdf)
        #expect(configError { try fixture.folders.renameFile(second.id, to: "testflight profile.PDF") } == .validation(.duplicateName))
        #expect(configError { try fixture.folders.renameFile(second.id, to: "a/b.pdf") } == .validation(.invalidName(.invalidCharacter)))
        #expect(configError { try fixture.folders.renameFile(second.id, to: "   ") } == .validation(.invalidName(.empty)))
        #expect(configError { try fixture.folders.renameFile(second.id, to: String(repeating: "é", count: 256)) }
            == .validation(.invalidName(.tooLong(maxLength: Limits.maxFolderFileNameLength))))
    }

    @Test func deletingAFileOrItsFolderRemovesTheBytes() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let mobile = try fixture.folders.createFolder(named: "Mobile")
        let development = try fixture.folders.createFolder(named: "Development", in: mobile)
        let kept = try fixture.folders.addFile(from: try fixture.source("a.pdf", Self.pdf), to: mobile)
        let deleted = try fixture.folders.addFile(from: try fixture.source("b.pdf", Self.pdf), to: mobile)
        let nested = try fixture.folders.addFile(from: try fixture.source("c.pdf", Self.pdf), to: development)

        try fixture.folders.deleteFiles([deleted.id])
        #expect(try fixture.folders.files(folderID: mobile) == [kept])

        try fixture.folders.deleteFolder(mobile)
        let blobs = try fixture.harness.database.read { tx in
            try [kept.id, deleted.id, nested.id].compactMap { try fixture.store.fetchFileBlob(fileID: $0, in: tx) }
        }
        #expect(blobs.isEmpty)
        #expect(fileError { try fixture.folders.addFile(from: try fixture.source("d.pdf", Self.pdf), to: mobile) } == .config(.folderNotFound))
    }

    @Test func aDEKRotationReSealsEveryFile() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let mobile = try fixture.folders.createFolder(named: "Mobile")
        let development = try fixture.folders.createFolder(named: "Development", in: mobile)
        let contents = [Self.pdf, Data("b".utf8), Data()]
        let files = [
            try fixture.folders.addFile(from: try fixture.source("a.pdf", contents[0]), to: mobile),
            try fixture.folders.addFile(from: try fixture.source("b.txt", contents[1]), to: mobile),
            try fixture.folders.addFile(from: try fixture.source("empty", contents[2]), to: development),
        ]
        let before = try files.map { try fixture.blob($0.id) }

        _ = try await fixture.harness.manager.rotateDEK(password: ConfigFixture.password)

        for (index, file) in files.enumerated() {
            #expect(try fixture.blob(file.id) != before[index])
            #expect(try await fixture.saved(file.id) == contents[index])
        }
    }

    @Test func aBlobMovedToAnotherFileDoesNotOpen() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let folder = try fixture.folders.createFolder(named: "Mobile")
        let first = try fixture.folders.addFile(from: try fixture.source("a.pdf", Self.pdf), to: folder)
        let second = try fixture.folders.addFile(from: try fixture.source("b.pdf", Data("other".utf8)), to: folder)
        let firstBlob = try fixture.blob(first.id)
        try fixture.harness.database.write { tx in
            try fixture.store.updateFileBlob(FolderFileBlobRecord(fileID: second.id, contentCiphertext: firstBlob), in: tx)
        }

        let url = fixture.directory.file("swapped")
        let authorization = try await fixture.authorization()
        #expect(fileError { try fixture.folders.saveFile(second.id, to: url, authorization: authorization) }
            == .config(.vault(.corrupted(.fieldDecryptionFailed))))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

func fileError(_ body: () throws -> Void) -> FolderFileError? {
    do {
        try body()
        return nil
    } catch let error as FolderFileError {
        return error
    } catch {
        return nil
    }
}
