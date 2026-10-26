import SwiftUI
import VaultCore

/// Where the deleted items live, which decides what the sheet says happens next.
enum DeleteItemsTarget: Equatable {
    /// A repository scope or an organization: the next Sync deletes them on GitHub.
    case gitHub
    /// A Key Vault: the next Sync deletes them there; Azure keeps them recoverable.
    case keyVault
    /// A folder: removed at once, nothing remote.
    case folder
}

/// What the "Delete?" sheet lists and says (boards Main2-Delete, Main2-DeleteKeyVault).
struct DeleteItemsSheetModel: Identifiable, Equatable {
    /// One item waiting for the confirmation.
    struct Entry: Equatable {
        let name: String
        let kind: ConfigKind
        /// On GitHub or in the Key Vault: the next Sync deletes it there.
        let isOnRemote: Bool
        let hasValue: Bool
        var isLinked = false
    }

    /// "Delete 2 secrets from api-service › production?"
    let title: String
    /// Keyed by kind too: a secret and a variable can share a name.
    let names: [ItemNameModel]
    /// Both kinds are listed (the title says "items"), so each row says its kind.
    let showsKind: Bool
    let notes: [String]

    var id: [ItemNameModel] {
        names
    }

    init(entries: [Entry], place: String, target: DeleteItemsTarget) {
        title = Self.title(entries, place: place)
        names = entries.map { ItemNameModel(kind: $0.kind, name: $0.name) }
        showsKind = Set(entries.map(\.kind)).count > 1
        notes = Self.notes(entries, target: target)
    }

    /// The count by kind ("2 secrets", "1 variable"), or "3 items" when both kinds are listed.
    private static func title(_ entries: [Entry], place: String) -> String {
        let secrets = entries.filter { $0.kind == .secret }.count
        let counted = if secrets == entries.count {
            String(inflected: AttributedString(localized: "delete.sheet.secrets", defaultValue: "^[\(secrets) secret](inflect: true)"))
        } else if secrets == 0 {
            String(inflected: AttributedString(localized: "delete.sheet.variables", defaultValue: "^[\(entries.count) variable](inflect: true)"))
        } else {
            String(inflected: AttributedString(localized: "delete.sheet.items", defaultValue: "^[\(entries.count) item](inflect: true)"))
        }
        return String(localized: "delete.sheet.title", defaultValue: "Delete \(counted) from \(place)?")
    }

    private static func notes(_ entries: [Entry], target: DeleteItemsTarget) -> [String] {
        let onRemote = entries.filter(\.isOnRemote).count
        let local = entries.count - onRemote
        switch target {
        case .folder:
            return [FolderCopy.deleteItemsMessage(count: entries.count)]
        case .gitHub:
            return [
                remoteNote(onRemote: onRemote, total: entries.count, target: target),
                localNote(local, isTheOnlyOne: onRemote == 0),
                irreversibleNote(entries),
            ].compactMap { $0 }
        case .keyVault:
            return [
                remoteNote(onRemote: onRemote, total: entries.count, target: target),
                localNote(local, isTheOnlyOne: onRemote == 0),
                onRemote > 0
                    ? String(
                        localized: "delete.sheet.keyVault.recoverable",
                        defaultValue: "Key Vault keeps deleted secrets recoverable for up to 90 days."
                    )
                    : nil,
                linkedNote(entries),
            ].compactMap { $0 }
        }
    }

    /// Only what reaches GitHub is lost there; FX Vault never had the value of a secret GitHub
    /// holds without one. nil when nothing listed is on GitHub.
    private static func irreversibleNote(_ entries: [Entry]) -> String? {
        let remote = entries.filter(\.isOnRemote)
        if remote.isEmpty {
            return nil
        }
        return remote.contains { $0.kind == .secret && !$0.hasValue }
            ? String(
                localized: "delete.sheet.gitHub.irreversible.valueMissing",
                defaultValue: "GitHub can’t undo this, and FX Vault has no copy of secrets without a value."
            )
            : String(localized: "delete.sheet.gitHub.irreversible", defaultValue: "GitHub can’t undo this.")
    }

    /// A Key Vault delete leaves the item's linked copies in repositories and folders alone.
    private static func linkedNote(_ entries: [Entry]) -> String? {
        guard entries.contains(where: \.isLinked) else { return nil }
        return entries.count == 1
            ? String(localized: "delete.sheet.keyVault.linked.one", defaultValue: "Its linked copies elsewhere stay.")
            : String(localized: "delete.sheet.keyVault.linked", defaultValue: "Their linked copies elsewhere stay.")
    }

    /// "They’re removed from GitHub at the next Sync, which asks again." nil when none is there.
    private static func remoteNote(onRemote: Int, total: Int, target: DeleteItemsTarget) -> String? {
        switch (target, onRemote) {
        case (_, 0):
            nil
        case (.keyVault, 1) where total == 1:
            String(localized: "delete.sheet.keyVault.one", defaultValue: "It’s deleted in Key Vault at the next Sync, which asks again.")
        case (.keyVault, _) where onRemote == total:
            String(localized: "delete.sheet.keyVault.all", defaultValue: "They’re deleted in Key Vault at the next Sync, which asks again.")
        case (.keyVault, 1):
            String(
                localized: "delete.sheet.keyVault.someOne",
                defaultValue: "One of them is deleted in Key Vault at the next Sync, which asks again."
            )
        case (.keyVault, _):
            String(
                localized: "delete.sheet.keyVault.some",
                defaultValue: "\(onRemote) of them are deleted in Key Vault at the next Sync, which asks again."
            )
        case (_, 1) where total == 1:
            String(localized: "delete.sheet.gitHub.one", defaultValue: "It’s removed from GitHub at the next Sync, which asks again.")
        case _ where onRemote == total:
            String(localized: "delete.sheet.gitHub.all", defaultValue: "They’re removed from GitHub at the next Sync, which asks again.")
        case (_, 1):
            String(
                localized: "delete.sheet.gitHub.someOne",
                defaultValue: "One of them is removed from GitHub at the next Sync, which asks again."
            )
        default:
            String(
                localized: "delete.sheet.gitHub.some",
                defaultValue: "\(onRemote) of them are removed from GitHub at the next Sync, which asks again."
            )
        }
    }

    /// The items never synced go at once: "The 2 never synced are removed now."
    private static func localNote(_ local: Int, isTheOnlyOne: Bool) -> String? {
        switch local {
        case 0:
            nil
        case 1 where isTheOnlyOne:
            String(localized: "delete.sheet.local.one", defaultValue: "It was never synced, so it’s removed now.")
        case _ where isTheOnlyOne:
            String(localized: "delete.sheet.local.all", defaultValue: "None of them was synced yet, so they’re removed now.")
        case 1:
            String(localized: "main.detail.delete.unsynced.one", defaultValue: "The one never synced is removed now.")
        default:
            String(localized: "main.detail.delete.unsynced.several", defaultValue: "The \(local) never synced are removed now.")
        }
    }
}

extension DeleteItemsSheetModel.Entry {
    init(_ row: ConfigRowModel) {
        self.init(name: row.name, kind: row.kind, isOnRemote: row.isSynced, hasValue: row.hasValue, isLinked: row.isLinked)
    }

    init(_ item: OrgItemModel) {
        self.init(name: item.name, kind: item.kind, isOnRemote: item.isOnGitHub, hasValue: item.hasValue)
    }
}

/// The "Delete?" sheet (boards Main2-Delete, Main2-DeleteKeyVault): the names in the grey list
/// box (it scrolls past `dialogListMaxHeight`), what happens next, Cancel and the red Delete.
/// Neither button is the default, so Return deletes nothing; Esc cancels.
struct DeleteItemsSheet: View {
    let model: DeleteItemsSheetModel
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        DialogSheet(title: model.title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.names) { name in
                        DeleteItemsNameRow(name: name, showsKind: model.showsKind)
                    }
                }
            }
            .frame(maxHeight: Theme.Layout.dialogListMaxHeight)
            .fxDialogListBox()
            VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
                ForEach(model.notes, id: \.self) { note in
                    DialogSentence(note)
                }
            }
        } actions: {
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: cancel)
                .fxButtonStyle(.outline, size: .dialog)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "main.detail.delete.confirm", defaultValue: "Delete"), role: .destructive, action: confirm)
                .fxButtonStyle(.destructive, size: .dialog)
                .accessibilityIdentifier(AccessibilityID.Place.deleteConfirm)
        }
        .frame(width: Theme.Layout.sheetWidth)
        .onKeyPress(.return) { .handled }
    }
}

/// `STRIPE_KEY` in mono, and `secret` muted after it when both kinds are listed.
private struct DeleteItemsNameRow: View {
    let name: ItemNameModel
    let showsKind: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(verbatim: name.name)
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsKind {
                Text(verbatim: SyncCopy.kindTitle(name.kind))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Layout.dialogListRowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Presents ``DeleteItemsSheet`` while `model` is set; closing it any other way cancels.
    func deleteItemsSheet(_ model: DeleteItemsSheetModel?, cancel: @escaping () -> Void, confirm: @escaping () -> Void) -> some View {
        sheet(item: Binding(get: { model }, set: { if $0 == nil { cancel() } })) { model in
            DeleteItemsSheet(model: model, cancel: cancel, confirm: confirm)
        }
    }
}
