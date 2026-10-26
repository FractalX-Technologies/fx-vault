import Foundation

/// A secret added from a file (1.0 F1, `file_detail`): the file's name, its line count and how
/// its bytes became the value. Plaintext metadata like item names (docs/SECURITY-MODEL.md); the
/// content is the item's sealed value.
public struct FileSecretModel: Sendable, Hashable, Codable {
    /// The file's name as chosen or dropped ("AuthKey_ABC123.p8"), without its folder.
    public var fileName: String
    /// The text file's lines; nil for a binary file.
    public var lineCount: Int?
    public var encoding: FileSecretEncoding

    public init(fileName: String, lineCount: Int?, encoding: FileSecretEncoding) {
        self.fileName = fileName
        self.lineCount = lineCount
        self.encoding = encoding
    }
}

/// How a file's bytes are stored as the secret's value.
public enum FileSecretEncoding: String, Sendable, Hashable, Codable, CaseIterable {
    /// The file's text, as is (trailing line breaks removed, D32).
    case text
    /// The file's bytes in Base64, on one line: binary files always, text files by choice (a
    /// workflow that decodes it gets the file back byte for byte).
    case base64
}
