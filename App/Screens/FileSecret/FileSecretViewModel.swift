import Foundation
import Observation
import VaultCore
import VaultData

/// Add file secret (1.0 F1; board Place-FileSheet). The name uses New Secret's rules (``names``);
/// the file's bytes stay in ``SecretBytes`` here until the save or the lock, never on screen. The
/// place's limit applies after Base64, and a binary file is always Base64.
@Observable
final class FileSecretViewModel: LockObserving {
    /// A file read for the sheet: its name and facts, never its bytes.
    struct FileModel: Hashable {
        let name: String
        let facts: FileSecretRules.FactsModel
    }

    let context: FileSecretContext
    /// The name field, its rules and the place, as New Secret has them.
    let names: ItemEditorViewModel
    private(set) var file: FileModel?
    /// Why the last chosen or dropped file could not be read.
    private(set) var readError: FileSecretReader.ReadError?
    /// The choice for a text file; a binary file is stored as Base64 whatever it says.
    var encoding: FileSecretEncoding = .text
    var alert: ErrorPresentationModel?
    private(set) var isSaving = false

    @ObservationIgnored private var bytes: SecretBytes?
    /// The name the last file suggested: the next file replaces it, unlike a typed name.
    @ObservationIgnored private var suggestedName: String?
    @ObservationIgnored private let readFile: (URL) throws(FileSecretReader.ReadError) -> SecretBytes

    init(
        context: FileSecretContext,
        dependencies: FeatureDependencies,
        readFile: @escaping (URL) throws(FileSecretReader.ReadError) -> SecretBytes = { url throws(FileSecretReader.ReadError) in
            try FileSecretReader.read(url)
        }
    ) {
        self.context = context
        self.readFile = readFile
        names = ItemEditorViewModel(context: ItemEditorContext(place: context.place, mode: .add(.secret)), dependencies: dependencies)
        dependencies.actions.addLockObserver(self)
    }

    /// Reads the place, then the dropped file. Call once when the sheet opens.
    func load() async {
        await names.load()
        if let url = context.fileURL {
            choose(url)
        }
    }

    /// Reads `url` in place of the current file. Its name becomes the secret's name unless the
    /// user typed one.
    func choose(_ url: URL) {
        dropFile()
        let read: SecretBytes
        do {
            read = try readFile(url)
        } catch {
            readError = error
            return
        }
        readError = nil
        bytes = read
        let fileName = url.lastPathComponent
        file = FileModel(name: fileName, facts: FileSecretRules.facts(of: read))
        if names.name.isEmpty || names.name == suggestedName {
            suggestedName = FileSecretRules.suggestedName(forFileName: fileName)
            names.name = suggestedName ?? ""
        }
    }

    // MARK: - Form

    var subtitle: String? {
        names.subtitle
    }

    var canEdit: Bool {
        names.canEdit
    }

    /// The encoding the value is stored with.
    var storedEncoding: FileSecretEncoding {
        guard let file else { return encoding }
        return FileSecretRules.encoding(encoding, for: file.facts)
    }

    /// Exact text is offered for a text file only.
    var isEncodingEditable: Bool {
        file?.facts.isText ?? true
    }

    /// Under Store as: why Base64, or that a binary file has no choice.
    var encodingHint: String {
        isEncodingEditable ? FileSecretCopy.base64Hint : FileSecretCopy.binaryHint
    }

    /// Exact text removes the file's trailing line breaks (D32).
    var removesTrailingLineBreaks: Bool {
        guard let file else { return false }
        return storedEncoding == .text && file.facts.trailingLineBreakCount > 0
    }

    var limitsLine: String {
        FileSecretCopy.limits(file: file?.facts)
    }

    /// The file could not be read, is empty, or is over the place's limit once stored.
    var fileNote: ConfigEditorNoteModel? {
        if let readError {
            return .error(FileSecretCopy.readError(readError))
        }
        guard let file else { return nil }
        let stored = FileSecretRules.storedByteCount(of: file.facts, as: storedEncoding)
        if stored == 0 {
            return .error(FileSecretCopy.empty)
        }
        if stored > names.maxValueBytes {
            return .error(FileSecretCopy.tooLarge(stored: stored, limit: names.maxValueBytes, encoding: storedEncoding))
        }
        return nil
    }

    var nameNote: ConfigEditorNoteModel? {
        names.nameNote
    }

    var canSave: Bool {
        names.loadState == .ready && canEdit && !isSaving && file != nil && fileNote == nil && names.isNameValid
    }

    // MARK: - Save

    /// Adds the secret. Returns true when the sheet can close.
    func save() -> Bool {
        guard canSave, let file, let bytes else { return false }
        isSaving = true
        defer { isSaving = false }
        let encoding = storedEncoding
        let value = FileSecretRules.value(of: bytes, as: encoding)
        defer { value.wipe() }
        do {
            _ = try names.addItem(value: value, file: FileSecretRules.model(fileName: file.name, facts: file.facts, encoding: encoding))
        } catch {
            alert = error.presentation
            return false
        }
        dropFile()
        return true
    }

    // MARK: - Hygiene

    /// Wipes the file's bytes and forgets the file (save, Cancel, lock, another file).
    func dropFile() {
        bytes?.wipe()
        bytes = nil
        file = nil
    }

    func vaultDidLock() {
        dropFile()
        readError = nil
    }
}
