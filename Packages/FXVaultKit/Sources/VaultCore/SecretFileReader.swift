import Darwin
import Foundation

/// Reads a file the user chose (a file secret, a `.env` import) straight into ``SecretBytes``:
/// never through `Data`, whose copies cannot be wiped, never more than `maxBytes`, and only a
/// regular file that stays the same while it is read.
public enum SecretFileReader {
    public enum ReadError: Error, Hashable, Sendable {
        case unreadable
        /// A folder, a device or a pipe: only a regular file is read.
        case notAFile
        case tooLarge(byteCount: Int)
        /// The file grew, shrank or was rewritten while it was read: it would be stored cut off.
        case changed
    }

    public static func read(_ url: URL, maxBytes: Int) throws(ReadError) -> SecretBytes {
        try read(url, maxBytes: maxBytes, afterMeasure: {})
    }

    /// `afterMeasure` runs between the size check and the read (tests change the file there).
    static func read(_ url: URL, maxBytes: Int, afterMeasure: () -> Void) throws(ReadError) -> SecretBytes {
        let path = url.path(percentEncoded: false)
        // Checked before open: opening a device node can act on the device, and a pipe waits.
        var listed = stat()
        guard stat(path, &listed) == 0 else { throw .unreadable }
        guard listed.st_mode & S_IFMT == S_IFREG else { throw .notAFile }
        // O_NONBLOCK and O_NOCTTY in case the path is swapped for a pipe or a terminal after stat.
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)
        guard descriptor >= 0 else { throw .unreadable }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw .unreadable }
        guard opened.st_mode & S_IFMT == S_IFREG else { throw .notAFile }
        guard opened.st_dev == listed.st_dev, opened.st_ino == listed.st_ino else { throw .changed }
        let size = Int(opened.st_size)
        guard size <= maxBytes else { throw .tooLarge(byteCount: size) }
        afterMeasure()
        let bytes = SecretBytes(count: size)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            readFully(descriptor, into: buffer)
        }
        guard let readCount else {
            bytes.wipe()
            throw .unreadable
        }
        guard readCount == size, isAtEnd(descriptor), isUnchanged(descriptor, since: opened) else {
            bytes.wipe()
            throw .changed
        }
        return bytes
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

    /// No byte after the measured size: the file did not grow while it was read.
    private static func isAtEnd(_ descriptor: Int32) -> Bool {
        var extra: UInt8 = 0
        var count: Int
        repeat {
            count = Darwin.read(descriptor, &extra, 1)
        } while count < 0 && errno == EINTR
        extra = 0
        return count == 0
    }

    /// Same size and modification time as when it was measured: not rewritten in place.
    private static func isUnchanged(_ descriptor: Int32, since measured: stat) -> Bool {
        var now = stat()
        guard fstat(descriptor, &now) == 0 else { return false }
        return now.st_size == measured.st_size
            && now.st_mtimespec.tv_sec == measured.st_mtimespec.tv_sec
            && now.st_mtimespec.tv_nsec == measured.st_mtimespec.tv_nsec
    }
}
