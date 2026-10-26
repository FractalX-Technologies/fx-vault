import Foundation
import VaultCore

/// The texts of file secrets (1.0 F1; boards Place-FileSheet, Place-FileDrop, Place-Table): the
/// sheet, the drop overlay and the label a file secret shows in the table and the notes. File
/// names show on screen only, never in a log.
nonisolated enum FileSecretCopy {
    static let menuTitle = String(localized: "fileSecret.menu", defaultValue: "Add File Secret…")
    static let title = String(localized: "fileSecret.title", defaultValue: "Add file secret")
    static let add = String(localized: "fileSecret.add", defaultValue: "Add")
    static let name = String(localized: "fileSecret.name", defaultValue: "Name")
    static let nameHint = String(localized: "fileSecret.name.hint", defaultValue: "Letters, digits and _ · saved in capitals")
    static let choose = String(localized: "fileSecret.choose", defaultValue: "Choose…")
    static let noFile = String(localized: "fileSecret.noFile", defaultValue: "No file chosen")
    static let storeAs = String(localized: "fileSecret.storeAs", defaultValue: "Store as")
    static let base64Hint = String(localized: "fileSecret.storeAs.base64Hint", defaultValue: "Use Base64 if your workflow decodes it")
    static let binaryHint = String(localized: "fileSecret.storeAs.binary", defaultValue: "Binary files are stored as Base64.")
    static let trailingLineBreaks = String(localized: "fileSecret.trailingLineBreaks", defaultValue: "Trailing line breaks are removed.")

    static func encoding(_ encoding: FileSecretEncoding) -> String {
        switch encoding {
        case .text: String(localized: "fileSecret.encoding.text", defaultValue: "Exact text")
        case .base64: String(localized: "fileSecret.encoding.base64", defaultValue: "Base64")
        }
    }

    // MARK: - Sizes

    /// "257 bytes", "1 byte" (locale digits).
    static func bytes(_ count: Int) -> String {
        String(inflected: AttributedString(localized: "fileSecret.bytes", defaultValue: "^[\(count) byte](inflect: true)"))
    }

    /// "6 lines", "1 line".
    static func lines(_ count: Int) -> String {
        String(inflected: AttributedString(localized: "fileSecret.lines", defaultValue: "^[\(count) line](inflect: true)"))
    }

    /// "· 257 bytes · 6 lines" after the file's name, or "· 1,204 bytes · binary".
    static func fileFacts(_ facts: FileSecretRules.FactsModel) -> String {
        let kind = facts.lineCount.map(lines) ?? String(localized: "fileSecret.binary", defaultValue: "binary")
        return "· " + PlaceCopy.subline([bytes(facts.byteCount), kind])
    }

    /// "GitHub 48,000 bytes · Key Vault 25,600", then "· this file 257 bytes (344 as Base64)"
    /// once a file is read (board Place-FileSheet).
    static func limits(file facts: FileSecretRules.FactsModel?) -> String {
        let places = String(
            localized: "fileSecret.limits",
            defaultValue: "GitHub \(Limits.maxValueBytes) bytes · Key Vault \(Limits.maxKeyVaultValueBytes)"
        )
        guard let facts else { return places }
        let file = String(
            localized: "fileSecret.limits.file",
            defaultValue: "this file \(bytes(facts.byteCount)) (\(facts.base64ByteCount) as Base64)"
        )
        return PlaceCopy.subline([places, file])
    }

    /// The stored value is over the place's limit.
    static func tooLarge(stored: Int, limit: Int, encoding: FileSecretEncoding) -> String {
        String(
            localized: "fileSecret.error.tooLarge",
            defaultValue: "Stored as \(Self.encoding(encoding)), this file is \(bytes(stored)). This place holds up to \(bytes(limit))."
        )
    }

    static let empty = String(localized: "fileSecret.error.empty", defaultValue: "This file is empty: there is nothing to store.")

    static func readError(_ error: FileSecretReader.ReadError) -> String {
        switch error {
        case .unreadable:
            String(localized: "fileSecret.error.unreadable", defaultValue: "FX Vault could not read this file.")
        case .notAFile:
            String(localized: "fileSecret.error.notAFile", defaultValue: "Choose a file, not a folder or a device.")
        case .tooLarge(let byteCount):
            String(
                localized: "fileSecret.error.tooLargeToRead",
                defaultValue: "This file is \(bytes(byteCount)). A secret holds up to \(bytes(Limits.maxValueBytes))."
            )
        }
    }

    // MARK: - Drop (board Place-FileDrop)

    static let dropTitle = String(localized: "fileSecret.drop.title", defaultValue: "Drop to add as a file secret")

    /// ".p8, .pem, .json · up to 48,000 bytes" (the place's limit: 25,600 for a Key Vault).
    static func dropDetail(limit: Int) -> String {
        let extensions = FileSecretRules.droppableExtensions.map { ".\($0)" }.joined(separator: ", ")
        return String(localized: "fileSecret.drop.detail", defaultValue: "\(extensions) · up to \(bytes(limit))")
    }

    static let notDroppableTitle = String(localized: "fileSecret.drop.refused.title", defaultValue: "This file can't be dropped here")
    static let notDroppableMessage = String(
        localized: "fileSecret.drop.refused.message",
        defaultValue: "Drop a .p8, .pem or .json file. For any other file, choose More › Add File Secret…."
    )

    // MARK: - Label (boards Place-Table, Main2-Repository)

    /// The table's label: "AuthKey.p8 · 6 lines", "cert.der · Base64".
    static func tableLabel(_ file: FileSecretModel) -> String {
        PlaceCopy.subline([file.fileName] + details(of: file))
    }

    /// The notes' label: "AuthKey.p8 · file · 6 lines".
    static func notesLabel(_ file: FileSecretModel) -> String {
        PlaceCopy.subline([file.fileName, String(localized: "fileSecret.label.file", defaultValue: "file")] + details(of: file))
    }

    /// VoiceOver: "From the file AuthKey.p8, 6 lines".
    static func accessibilityLabel(_ file: FileSecretModel) -> String {
        let details = details(of: file).joined(separator: ", ")
        return details.isEmpty
            ? String(localized: "fileSecret.label.accessibility", defaultValue: "From the file \(file.fileName)")
            : String(localized: "fileSecret.label.accessibility.details", defaultValue: "From the file \(file.fileName), \(details)")
    }

    /// Its lines (a text file) and "Base64" when stored that way.
    private static func details(of file: FileSecretModel) -> [String] {
        [file.lineCount.map(lines), file.encoding == .base64 ? encoding(.base64) : nil].compactMap(\.self)
    }
}
