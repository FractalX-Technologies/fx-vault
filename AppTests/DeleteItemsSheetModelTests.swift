import Testing
import VaultCore
@testable import FXVault

/// The "Delete?" sheet's title and notes (boards Main2-Delete, Main2-DeleteKeyVault).
@MainActor
@Suite("Delete items sheet")
struct DeleteItemsSheetModelTests {
    private static func entry(_ name: String, _ kind: ConfigKind = .secret, onRemote: Bool = true, hasValue: Bool = true) -> DeleteItemsSheetModel.Entry {
        DeleteItemsSheetModel.Entry(name: name, kind: kind, isOnRemote: onRemote, hasValue: hasValue)
    }

    @Test func theTitleCountsByKindAndNamesThePlace() {
        let place = "api-service › production"
        let secrets = DeleteItemsSheetModel(entries: [Self.entry("JWT_SECRET"), Self.entry("REDIS_URL")], place: place, target: .gitHub)
        #expect(secrets.title == "Delete 2 secrets from api-service › production?")
        #expect(secrets.names == ["JWT_SECRET", "REDIS_URL"])
        #expect(secrets.notes == [
            "They’re removed from GitHub at the next Sync, which asks again.",
            "GitHub can’t undo this.",
        ])

        let variable = DeleteItemsSheetModel(entries: [Self.entry("LOG_LEVEL", .variable)], place: place, target: .gitHub)
        #expect(variable.title == "Delete 1 variable from api-service › production?")
        #expect(variable.notes.first == "It’s removed from GitHub at the next Sync, which asks again.")

        let both = DeleteItemsSheetModel(entries: [Self.entry("A"), Self.entry("B", .variable)], place: place, target: .gitHub)
        #expect(both.title == "Delete 2 items from api-service › production?")
    }

    @Test func aSecretWithoutValueSaysFXVaultHasNoCopy() {
        let model = DeleteItemsSheetModel(entries: [Self.entry("JWT_SECRET", hasValue: false)], place: "api-service", target: .gitHub)
        #expect(model.notes.last == "GitHub can’t undo this, and FX Vault has no copy of secrets without a value.")
    }

    @Test func aKeyVaultSaysItKeepsDeletedSecretsRecoverable() {
        let model = DeleteItemsSheetModel(
            entries: [Self.entry("api-jwt-secret"), Self.entry("redis-connection")],
            place: "kv-example-prod",
            target: .keyVault
        )
        #expect(model.title == "Delete 2 secrets from kv-example-prod?")
        #expect(model.notes == [
            "They’re deleted in Key Vault at the next Sync, which asks again.",
            "Key Vault keeps deleted secrets recoverable for up to 90 days.",
        ])

        let mixed = DeleteItemsSheetModel(
            entries: [Self.entry("pushed"), Self.entry("new-a", onRemote: false), Self.entry("new-b", onRemote: false)],
            place: "kv-example-prod",
            target: .keyVault
        )
        #expect(mixed.notes == [
            "One of them is deleted in Key Vault at the next Sync, which asks again.",
            "The 2 never synced are removed now.",
            "Key Vault keeps deleted secrets recoverable for up to 90 days.",
        ])
    }

    @Test func aFolderRemovesThemAtOnce() {
        let model = DeleteItemsSheetModel(entries: [Self.entry("STRIPE_KEY", onRemote: false)], place: "Stripe test", target: .folder)
        #expect(model.title == "Delete 1 secret from Stripe test?")
        #expect(model.notes == ["They are removed from this folder now. Copies in repositories and other folders stay."])
    }
}
