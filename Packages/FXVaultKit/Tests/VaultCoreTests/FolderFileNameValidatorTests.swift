import Testing
import VaultCore

/// Folder file names (v23): what Save As… can use, and Finder's "name 2.ext" for a second copy.
@Suite("FolderFileNameValidator")
struct FolderFileNameValidatorTests {
    @Test func aNameIsTrimmedAndComposed() throws {
        #expect(try FolderFileNameValidator.validated("  Profile.pdf \n") == "Profile.pdf")
        #expect(try FolderFileNameValidator.validated("Re\u{0301}sume\u{0301}.pdf") == "Résumé.pdf")
        #expect(try FolderFileNameValidator.validated(".env.production") == ".env.production")
    }

    @Test func aNameSaveAsCannotUseIsRefused() {
        #expect(throws: ValidationError.invalidName(.empty)) { try FolderFileNameValidator.validated(" ") }
        #expect(throws: ValidationError.invalidName(.invalidCharacter)) { try FolderFileNameValidator.validated("a/b.pdf") }
        #expect(throws: ValidationError.invalidName(.invalidCharacter)) { try FolderFileNameValidator.validated("a:b.pdf") }
        #expect(throws: ValidationError.invalidName(.invalidCharacter)) { try FolderFileNameValidator.validated("a\u{0}b") }
        #expect(throws: ValidationError.invalidName(.invalidCharacter)) { try FolderFileNameValidator.validated(" . ") }
        #expect(throws: ValidationError.invalidName(.invalidCharacter)) { try FolderFileNameValidator.validated("..") }
        #expect(throws: ValidationError.invalidName(.tooLong(maxLength: Limits.maxFolderFileNameLength))) {
            try FolderFileNameValidator.validated(String(repeating: "a", count: Limits.maxFolderFileNameLength + 1))
        }
    }

    @Test func aTakenNameGetsTheNextNumberBeforeItsExtension() {
        let taken: Set = ["build.ipa", "build 2.ipa", "notes"]
        #expect(FolderFileNameValidator.available("Build.ipa", taken: taken) == "Build 3.ipa")
        #expect(FolderFileNameValidator.available("notes", taken: taken) == "notes 2")
        #expect(FolderFileNameValidator.available("other.ipa", taken: taken) == "other.ipa")
    }
}
