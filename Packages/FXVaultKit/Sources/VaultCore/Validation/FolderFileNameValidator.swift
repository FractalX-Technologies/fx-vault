import Foundation

/// Folder file names (v23): what a name may hold, and a free name for a file added twice. Two
/// names are the same when their ``FolderNameValidator/foldKey(_:)`` keys are.
public enum FolderFileNameValidator {
    /// `name` in NFC with surrounding whitespace removed. Throws `.invalidName`: `.empty`,
    /// `.tooLong` over ``Limits/maxFolderFileNameLength``, or `.invalidCharacter` for `/`, `:`, a
    /// control character, `.` or `..` (Save As… would refuse the name or change it).
    public static func validated(_ name: String) throws(ValidationError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !trimmed.isEmpty else { throw .invalidName(.empty) }
        guard trimmed.unicodeScalars.count <= Limits.maxFolderFileNameLength else {
            throw .invalidName(.tooLong(maxLength: Limits.maxFolderFileNameLength))
        }
        guard trimmed != ".", trimmed != "..",
              !trimmed.unicodeScalars.contains(where: { $0 == "/" || $0 == ":" || CharacterSet.controlCharacters.contains($0) })
        else {
            throw .invalidName(.invalidCharacter)
        }
        return trimmed
    }

    /// `name`, or `name 2.ext`, `name 3.ext`… (Finder's pattern) for the first one `taken`
    /// doesn't hold. `taken` holds fold keys.
    public static func available(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(FolderNameValidator.foldKey(name)) else { return name }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            if !taken.contains(FolderNameValidator.foldKey(candidate)) { return candidate }
            number += 1
        }
    }
}
