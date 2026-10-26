import Darwin
import Foundation
import Testing
@testable import VaultCore

/// A chosen file read into ``SecretBytes`` (1.0 F1, and the `.env` import): real files in a
/// temporary folder of the test's own. Contents are synthetic.
@Suite("Secret file reader")
struct SecretFileReaderTests {
    static let text = "-----BEGIN FIXTURE-----\nFXV1\n-----END FIXTURE-----\n"

    /// A folder of its own under the temporary directory; removed by ``remove()``.
    struct Files {
        let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("fxv-reader-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func write(_ name: String, _ text: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func string(_ bytes: SecretBytes) -> String? {
        bytes.withUnsafeBytes { String(bytes: $0, encoding: .utf8) }
    }

    @Test func aRegularFileIsReadWhole() throws {
        let files = try Files()
        defer { files.remove() }
        let url = try files.write("AuthKey.p8", Self.text)
        let bytes = try SecretFileReader.read(url, maxBytes: 1_000)
        defer { bytes.wipe() }
        #expect(Self.string(bytes) == Self.text)

        let spaced = try files.write("my key %20.pem", Self.text)
        #expect(try SecretFileReader.read(spaced, maxBytes: 1_000).count == Self.text.utf8.count, "the path is not percent-decoded twice")
        let empty = try files.write("empty.json", "")
        #expect(try SecretFileReader.read(empty, maxBytes: 1_000).count == 0)
    }

    @Test func onlyARegularFileWithinTheLimitIsRead() throws {
        let files = try Files()
        defer { files.remove() }
        #expect(throws: SecretFileReader.ReadError.unreadable) {
            try SecretFileReader.read(files.folder.appendingPathComponent("missing.p8"), maxBytes: 1_000)
        }
        #expect(throws: SecretFileReader.ReadError.notAFile) {
            try SecretFileReader.read(files.folder, maxBytes: 1_000)
        }
        #expect(throws: SecretFileReader.ReadError.notAFile) {
            try SecretFileReader.read(URL(fileURLWithPath: "/dev/null"), maxBytes: 1_000)
        }
        let url = try files.write("big.json", String(repeating: "a", count: 1_001))
        #expect(throws: SecretFileReader.ReadError.tooLarge(byteCount: 1_001)) {
            try SecretFileReader.read(url, maxBytes: 1_000)
        }
    }

    /// Opening a named pipe for reading waits for a writer: the pipe is refused, never opened.
    @Test(.timeLimit(.minutes(1))) func aNamedPipeIsRefusedWithoutWaiting() throws {
        let files = try Files()
        defer { files.remove() }
        let pipe = files.folder.appendingPathComponent("key.pem")
        #expect(mkfifo(pipe.path(percentEncoded: false), S_IRUSR | S_IWUSR) == 0)
        #expect(throws: SecretFileReader.ReadError.notAFile) {
            try SecretFileReader.read(pipe, maxBytes: 1_000)
        }
    }

    /// A file that grows, shrinks or is rewritten after it was measured is refused, not stored
    /// cut off.
    @Test func aFileThatChangesWhileItIsReadIsRefused() throws {
        let files = try Files()
        defer { files.remove() }
        let url = try files.write("service-account.json", Self.text)
        let grow = {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("more\n".utf8))
            try? handle.close()
        }
        #expect(throws: SecretFileReader.ReadError.changed) {
            try SecretFileReader.read(url, maxBytes: 1_000, afterMeasure: grow)
        }

        let shrinking = try files.write("shrinking.json", Self.text)
        #expect(throws: SecretFileReader.ReadError.changed) {
            try SecretFileReader.read(shrinking, maxBytes: 1_000) {
                _ = truncate(shrinking.path(percentEncoded: false), 4)
            }
        }

        let rewritten = try files.write("rewritten.json", Self.text)
        #expect(throws: SecretFileReader.ReadError.changed) {
            try SecretFileReader.read(rewritten, maxBytes: 1_000) {
                guard let handle = try? FileHandle(forWritingTo: rewritten) else { return }
                try? handle.write(contentsOf: Data(String(repeating: "x", count: Self.text.utf8.count).utf8))
                try? handle.close()
            }
        }
    }
}
