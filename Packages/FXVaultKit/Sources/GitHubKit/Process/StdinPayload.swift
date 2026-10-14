import Foundation
import VaultCore

/// The bytes written to a child's stdin (tasks/todo.md §5.10, §5.12).
///
/// stdin is always a pipe. The runner writes the payload, closes the pipe, then **wipes the
/// payload's buffer**: ownership of the `SecretBytes` passes to the runner. Callers that need
/// the value again (for a retry) pass a copy.
public struct StdinPayload: Sendable {
    /// No input: the pipe is closed immediately, so the child reads end-of-file.
    public static let empty = StdinPayload(storage: nil)

    let storage: SecretBytes?

    private init(storage: SecretBytes?) {
        self.storage = storage
    }

    /// Transfers `bytes` to the runner, which wipes them after writing.
    public init(transferring bytes: SecretBytes) {
        storage = bytes
    }

    /// Number of bytes that will be written.
    public var count: Int {
        storage?.count ?? 0
    }

    /// Wipes the payload without writing it (for example when the process never started).
    public func discard() {
        storage?.wipe()
    }
}

extension StdinPayload: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "StdinPayload(\(count) bytes)"
    }

    public var debugDescription: String {
        description
    }
}
