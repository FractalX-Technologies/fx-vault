import Darwin
import Foundation
import Testing
import VaultCore
@testable import EnvTools

/// The `stat` fields the tests check.
private struct FileFacts: Sendable, Equatable {
    let permissions: mode_t
    let owner: uid_t
    let size: off_t
    let isRegular: Bool
}

private func facts(atPath path: String) -> FileFacts? {
    var status = stat()
    guard lstat(path, &status) == 0 else { return nil }
    return FileFacts(
        permissions: status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO),
        owner: status.st_uid,
        size: status.st_size,
        isRegular: status.st_mode & S_IFMT == S_IFREG
    )
}

@Suite("SecureFileWriter")
struct SecureFileWriterTests {
    private let ownerOnly: mode_t = S_IRUSR | S_IWUSR
    private let worldReadable: Int16 = 0o644

    private func leftovers(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasPrefix(".fxvault-") }
    }

    @Test func createsAnOwnerOnlyFileWithNoWiderWindow() throws {
        let directory = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: ".env")

        let observed = LockedBox<FileFacts?>(nil)
        let writer = SecureFileWriter { temporaryPath in
            // Runs right after open(2), before any byte is written.
            observed.value = facts(atPath: temporaryPath)
        }
        try writer.write(SecretBytes(utf8: "A=1\n"), to: destination)

        let temporary = try #require(observed.value)
        #expect(temporary == FileFacts(permissions: ownerOnly, owner: getuid(), size: 0, isRegular: true))

        let final = try #require(facts(atPath: destination.path(percentEncoded: false)))
        #expect(final == FileFacts(permissions: ownerOnly, owner: getuid(), size: 4, isRegular: true))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "A=1\n")
        #expect(try leftovers(in: directory).isEmpty)
    }

    @Test func refusesAnExistingFileByDefault() throws {
        let directory = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: ".env")
        try Data("old".utf8).write(to: destination)

        #expect(throws: SecureFileWriteError.destinationExists) {
            try SecureFileWriter().write(SecretBytes(utf8: "new"), to: destination)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "old")
        #expect(try leftovers(in: directory).isEmpty)
    }

    @Test func replacesAWorldReadableFileWithAnOwnerOnlyOne() throws {
        let directory = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: ".env")
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: worldReadable)],
            ofItemAtPath: destination.path(percentEncoded: false)
        )

        try SecureFileWriter().write(SecretBytes(utf8: "new"), to: destination, existingFile: .replace)

        #expect(facts(atPath: destination.path(percentEncoded: false))?.permissions == ownerOnly)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
    }

    @Test(
        "refuses symbolic links",
        arguments: [SecureFileWriter.ExistingFilePolicy.fail, .replace]
    )
    func refusesSymbolicLinks(policy: SecureFileWriter.ExistingFilePolicy) throws {
        let directory = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "target.txt")
        try Data("untouched".utf8).write(to: target)
        let link = directory.appending(path: ".env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: SecureFileWriteError.destinationIsSymbolicLink) {
            try SecureFileWriter().write(SecretBytes(utf8: "secret"), to: link, existingFile: policy)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
        #expect(try leftovers(in: directory).isEmpty)
    }

    @Test func refusesADanglingSymbolicLink() throws {
        let directory = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "missing.txt")
        let link = directory.appending(path: ".env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        #expect(throws: SecureFileWriteError.destinationIsSymbolicLink) {
            try SecureFileWriter().write(SecretBytes(utf8: "secret"), to: link, existingFile: .replace)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path(percentEncoded: false)))
    }

    @Test func refusesAFolder() throws {
        let directory = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        #expect(throws: SecureFileWriteError.destinationIsNotRegularFile) {
            try SecureFileWriter().write(SecretBytes(utf8: "x"), to: folder, existingFile: .replace)
        }
    }

    @Test func refusesAMissingFolderAndNonFileURLs() throws {
        let directory = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "missing/.env")
        #expect(throws: SecureFileWriteError.parentDirectoryUnavailable) {
            try SecureFileWriter().write(SecretBytes(utf8: "x"), to: missing)
        }
        let remote = try #require(URL(string: "https://example.test/.env"))
        #expect(throws: SecureFileWriteError.notAFileURL) {
            try SecureFileWriter().write(SecretBytes(utf8: "x"), to: remote)
        }
    }

    @Test func writesDataAndEmptyFiles() throws {
        let directory = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appending(path: "share.fxvault")
        let payload = Data((0...255).map { UInt8($0) })
        try SecureFileWriter().write(payload, to: package)
        #expect(try Data(contentsOf: package) == payload)
        #expect(facts(atPath: package.path(percentEncoded: false))?.permissions == ownerOnly)

        let empty = directory.appending(path: "empty.env")
        try SecureFileWriter().write(SecretBytes(count: 0), to: empty)
        #expect(facts(atPath: empty.path(percentEncoded: false))?.size == 0)
        #expect(facts(atPath: empty.path(percentEncoded: false))?.permissions == ownerOnly)
    }

    @Test func leavesTheCallersBufferIntact() throws {
        let directory = try TestValues.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = SecretBytes(utf8: "A=1\n")
        try SecureFileWriter().write(contents, to: directory.appending(path: ".env"))
        #expect(contents.utf8String() == "A=1\n")
    }
}
