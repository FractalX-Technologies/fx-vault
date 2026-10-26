import Testing
import VaultCore
@testable import FXVault

/// The "Delete?" sheet's title and notes (boards Main2-Delete, Main2-DeleteKeyVault).
@MainActor
@Suite("Delete items sheet")
struct DeleteItemsSheetModelTests {
    private static func entry(
        _ name: String,
        _ kind: ConfigKind = .secret,
        onRemote: Bool = true,
        hasValue: Bool = true,
        isLinked: Bool = false
    ) -> DeleteItemsSheetModel.Entry {
        DeleteItemsSheetModel.Entry(name: name, kind: kind, isOnRemote: onRemote, hasValue: hasValue, isLinked: isLinked)
    }

    @Test func theTitleCountsByKindAndNamesThePlace() {
        let place = "api-service › production"
        let secrets = DeleteItemsSheetModel(entries: [Self.entry("JWT_SECRET"), Self.entry("REDIS_URL")], place: place, target: .gitHub)
        #expect(secrets.title == "Delete 2 secrets from api-service › production?")
        #expect(secrets.names.map(\.name) == ["JWT_SECRET", "REDIS_URL"])
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

    /// A converted item can leave a secret and a variable with one name: two rows, each saying
    /// its kind.
    @Test func aSecretAndAVariableWithOneNameAreTwoRows() {
        let model = DeleteItemsSheetModel(entries: [Self.entry("API_KEY"), Self.entry("API_KEY", .variable)], place: "api-service", target: .gitHub)
        #expect(model.names.map(\.kind) == [.secret, .variable])
        #expect(Set(model.names.map(\.id)).count == 2)
        #expect(model.showsKind)
        #expect(!DeleteItemsSheetModel(entries: [Self.entry("API_KEY")], place: "api-service", target: .gitHub).showsKind)
    }

    @Test func aSecretWithoutValueSaysFXVaultHasNoCopy() {
        let model = DeleteItemsSheetModel(entries: [Self.entry("JWT_SECRET", hasValue: false)], place: "api-service", target: .gitHub)
        #expect(model.notes.last == "GitHub can’t undo this, and FX Vault has no copy of secrets without a value.")

        // A secret never synced has nothing on GitHub to lose.
        let local = DeleteItemsSheetModel(
            entries: [Self.entry("PUSHED"), Self.entry("NEW", onRemote: false, hasValue: false)],
            place: "api-service",
            target: .gitHub
        )
        #expect(local.notes.last == "GitHub can’t undo this.")
        let onlyLocal = DeleteItemsSheetModel(entries: [Self.entry("NEW", onRemote: false, hasValue: false)], place: "api-service", target: .gitHub)
        #expect(onlyLocal.notes == ["It was never synced, so it’s removed now."])
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

        let linked = DeleteItemsSheetModel(entries: [Self.entry("api-jwt-secret", isLinked: true)], place: "kv-example-prod", target: .keyVault)
        #expect(linked.notes.last == "Its linked copies elsewhere stay.")
        let linkedMany = DeleteItemsSheetModel(
            entries: [Self.entry("api-jwt-secret", isLinked: true), Self.entry("redis-connection")],
            place: "kv-example-prod",
            target: .keyVault
        )
        #expect(linkedMany.notes.last == "Their linked copies elsewhere stay.")
    }

    @Test func aFolderRemovesThemAtOnce() {
        let model = DeleteItemsSheetModel(entries: [Self.entry("STRIPE_KEY", onRemote: false)], place: "Stripe test", target: .folder)
        #expect(model.title == "Delete 1 secret from Stripe test?")
        #expect(model.notes == ["It’s removed from this folder now. Copies in repositories and other folders stay."])
        let two = DeleteItemsSheetModel(entries: [Self.entry("A", onRemote: false), Self.entry("B", onRemote: false)], place: "Stripe test", target: .folder)
        #expect(two.notes == ["They are removed from this folder now. Copies in repositories and other folders stay."])
    }
}
