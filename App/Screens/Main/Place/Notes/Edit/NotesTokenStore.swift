import Foundation
import VaultCore

/// The values behind an edit's tokens (1.0 N2), kept out of the text. A value set while editing
/// is normalized first (D32); setting one in place makes a new token (``replacement(for:value:)``)
/// so Undo brings the old one back by id. Every value is wiped when the edit ends.
final class NotesTokenStore {
    /// How a token draws: its chip in the text.
    enum Display: Hashable {
        /// `••••`, with the size when it is over the place's limit.
        case masked(oversizeBytes: Int?)
        /// A one-line secret value pasted or typed in this edit, drawn in its chip like a note's
        /// text: the user has it on screen already. It stays out of the text, undo and copies.
        case visible(String)
        /// The dashed "Set value…" of a secret without a value.
        case setValue
        /// A variable value with line breaks: "3 lines".
        case lines(Int)
        /// A secret's value from a file (1.0 F1): "AuthKey.p8 · file · 6 lines".
        case file(FileSecretModel)
    }

    private struct Entry {
        let kind: ConfigKind
        let origin: ConfigItemID?
        let originHasValue: Bool
        let file: FileSecretModel?
        /// A variable's current value, or any value set while editing.
        var value: SecretBytes?
        var isNew = false
    }

    private var entries: [NotesTokenID: Entry] = [:]

    /// A token for `origin`'s value, or a new line's (`origin` nil). `value` is a variable's own,
    /// `file` the one a secret's value came from.
    func make(
        kind: ConfigKind,
        origin: ConfigItemID? = nil,
        originHasValue: Bool = false,
        value: SecretBytes? = nil,
        file: FileSecretModel? = nil
    ) -> NotesTokenID {
        let id = NotesTokenID()
        entries[id] = Entry(kind: kind, origin: origin, originHasValue: originHasValue, file: file, value: value)
        return id
    }

    /// A fresh token of `id`'s kind, without its item or value: a copy of a line is a new line.
    func duplicate(_ id: NotesTokenID) -> NotesTokenID? {
        entries[id].map { make(kind: $0.kind) }
    }

    /// Sets a value typed, pasted or generated while editing. Throws `.emptyValue` for nothing
    /// but line breaks; a value over the place's limit is kept and shown as the line's problem.
    func setValue(_ value: SecretBytes, for id: NotesTokenID) throws(ValidationError) {
        guard entries[id] != nil else { return }
        let normalized = value.prefix(value.count - Self.trailingNewlines(in: value))
        guard !normalized.isEmpty else {
            normalized.wipe()
            throw .emptyValue
        }
        entries[id]?.value?.wipe()
        entries[id]?.value = normalized
        entries[id]?.isNew = true
    }

    /// A new token for `id`'s line holding `value`: the same item, kind and file, the value set
    /// as by ``setValue(_:for:)``. The old token keeps what it had, for Undo.
    func replacement(for id: NotesTokenID, value: SecretBytes) throws(ValidationError) -> NotesTokenID {
        let entry = entries[id]
        let fresh = make(
            kind: entry?.kind ?? .secret,
            origin: entry?.origin,
            originHasValue: entry?.originHasValue ?? false,
            file: entry?.file
        )
        do {
            try setValue(value, for: fresh)
        } catch {
            entries[fresh] = nil
            throw error
        }
        return fresh
    }

    func kind(of id: NotesTokenID) -> ConfigKind? {
        entries[id]?.kind
    }

    func origin(of id: NotesTokenID) -> ConfigItemID? {
        entries[id]?.origin
    }

    /// A copy of the value the save writes; nil when the token keeps its item's. The caller wipes it.
    func valueToSave(_ id: NotesTokenID) -> SecretBytes? {
        guard let entry = entries[id], entry.isNew || entry.origin == nil else { return nil }
        return entry.value?.copy()
    }

    /// A copy of a variable token's value, for Set value…. The caller wipes it.
    func variableValue(_ id: NotesTokenID) -> SecretBytes? {
        guard let entry = entries[id], entry.kind == .variable else { return nil }
        return entry.value?.copy()
    }

    func model(_ id: NotesTokenID) -> NotesTokenModel? {
        guard let entry = entries[id] else { return nil }
        return NotesTokenModel(
            id: id,
            kind: entry.kind,
            origin: entry.origin,
            hasValue: entry.value != nil || entry.originHasValue,
            newValueBytes: entry.isNew ? entry.value?.count : nil
        )
    }

    var models: [NotesTokenID: NotesTokenModel] {
        Dictionary(uniqueKeysWithValues: entries.keys.compactMap { id in model(id).map { (id, $0) } })
    }

    func display(_ id: NotesTokenID, maxValueBytes: Int) -> Display {
        guard let entry = entries[id] else { return .setValue }
        if entry.kind == .variable, let value = entry.value {
            return .lines(Self.lineCount(of: value))
        }
        guard entry.value != nil || entry.originHasValue else { return .setValue }
        if !entry.isNew, let file = entry.file {
            return .file(file)
        }
        let bytes = entry.isNew ? entry.value?.count : nil
        if let bytes, bytes <= maxValueBytes, let text = entry.value?.utf8String(), !text.contains(where: \.isNewline) {
            return .visible(text)
        }
        return .masked(oversizeBytes: bytes.flatMap { $0 > maxValueBytes ? $0 : nil })
    }

    /// Wipes every value (the edit ended: saved, cancelled, another place, lock).
    func wipe() {
        for entry in entries.values {
            entry.value?.wipe()
        }
        entries.removeAll()
    }

    private static func trailingNewlines(in value: SecretBytes) -> Int {
        value.withUnsafeBytes { ValueNormalizer.trailingNewlineCount(in: $0) }
    }

    private static func lineCount(of value: SecretBytes) -> Int {
        value.withUnsafeBytes { bytes in
            bytes.reduce(1) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
        }
    }
}
