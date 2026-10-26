import Darwin
import Foundation
import VaultCore

/// Reads a chosen or dropped file for Add file secret (1.0 F1) straight into ``SecretBytes``:
/// never through `Data`, whose copies cannot be wiped, and never more than `maxBytes`, so a
/// large file is refused by its size before anything is read.
nonisolated enum FileSecretReader {
    enum ReadError: Error, Hashable {
        case unreadable
        /// A folder, a device or a pipe: only a regular file is read.
        case notAFile
        case tooLarge(byteCount: Int)
    }

    static func read(_ url: URL, maxBytes: Int = Limits.maxFileSecretReadBytes) throws(ReadError) -> SecretBytes {
        // O_NONBLOCK: opening a named pipe must not wait for a writer; it is refused below.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw .unreadable }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notAFile }
        let size = Int(info.st_size)
        guard size <= maxBytes else { throw .tooLarge(byteCount: size) }
        let bytes = SecretBytes(count: size)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            readFully(descriptor, into: buffer)
        }
        guard let readCount else {
            bytes.wipe()
            throw .unreadable
        }
        guard readCount < size else { return bytes }
        // The file shrank after it was measured: keep what was read.
        let shorter = bytes.prefix(readCount)
        bytes.wipe()
        return shorter
    }

    /// Reads until `buffer` is full or the file ends; nil on a read error.
    private static func readFully(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Int? {
        guard let base = buffer.baseAddress else { return 0 }
        var total = 0
        while total < buffer.count {
            let count = Darwin.read(descriptor, base + total, buffer.count - total)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            guard count > 0 else { break }
            total += count
        }
        return total
    }
}
