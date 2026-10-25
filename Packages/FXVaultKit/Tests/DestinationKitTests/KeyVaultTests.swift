import Foundation
import Testing
@testable import DestinationKit
import VaultCore

/// Azure Key Vault data plane through ``FakeHTTPTransport`` (api-version 7.4).
@Suite("Azure Key Vault")
struct KeyVaultTests {
    @Test func listFollowsNextLinkAndMapsNames() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("keyvault/list-page1.json"), method: .get, pathPrefix: "/secrets")
        transport.enqueue(try Fixture.response("keyvault/list-page2.json"), method: .get, pathPrefix: "/secrets")
        let items = try await TestValues.keyVault(transport).list()

        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url.absoluteString == "https://kv-sample-prod.vault.azure.net/secrets?api-version=7.4&maxresults=25")
        #expect(requests[1].url.absoluteString == "https://kv-sample-prod.vault.azure.net:443/secrets?api-version=7.4&$skiptoken=FIXTURE-PAGE-2&maxresults=25")
        #expect(requests.allSatisfy { $0.method == .get && $0.bearerToken == TestValues.azureToken && $0.body == nil })
        #expect(requests[0].headerNames == ["accept", "authorization"])

        let byRemote = Dictionary(uniqueKeysWithValues: items.map { ($0.remoteName, $0) })
        #expect(items.map(\.remoteName) == ["DATABASE-URL", "api-url", "OLD-FLAG", "sample-cert", "9-LIVES", "GITHUB-SAMPLE", "SERVICE-ENDPOINT"])

        let database = try #require(byRemote["DATABASE-URL"])
        #expect(database.name == "DATABASE_URL")
        #expect(database.unusableReason == nil && database.isUsable)
        #expect(database.kind == .secret)
        #expect(database.version == "1790000000")
        #expect(database.updatedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(database.isValueReadable)

        #expect(byRemote["api-url"]?.name == "API_URL", "lowercase dashes map to an uppercase name")
        #expect(byRemote["OLD-FLAG"]?.unusableReason == .disabled)
        #expect(byRemote["OLD-FLAG"]?.name == "OLD_FLAG", "a disabled secret keeps its name")
        #expect(byRemote["OLD-FLAG"]?.isValueReadable == false)
        #expect(byRemote["sample-cert"]?.unusableReason == .managed)
        #expect(byRemote["9-LIVES"]?.unusableReason == .invalidName(.invalidName(.leadingDigit)))
        #expect(byRemote["9-LIVES"]?.name == nil)
        #expect(byRemote["GITHUB-SAMPLE"]?.unusableReason == .invalidName(.invalidName(.reservedPrefix)))
        #expect(byRemote["SERVICE-ENDPOINT"]?.isUsable == true)
    }

    @Test func nextLinkToAnotherHostIsRefused() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("keyvault/list-foreign-next.json"))
        await #expect(throws: DestinationError.disallowedHost) {
            try await TestValues.keyVault(transport).list()
        }
        #expect(transport.requests.count == 1)
    }

    @Test func repeatedNextLinkStops() async throws {
        let transport = FakeHTTPTransport()
        let page = #"{"value":[],"nextLink":"https://kv-sample-prod.vault.azure.net/secrets?api-version=7.4&$skiptoken=SAME"}"#
        transport.stub(.json(page))
        await #expect(throws: DestinationError.decoding) {
            try await TestValues.keyVault(transport).list()
        }
        #expect(transport.requests.count == 2)
    }

    @Test func listWithoutIDIsMalformed() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(.json(#"{"value":[{"attributes":{"enabled":true}}]}"#))
        await #expect(throws: DestinationError.decoding) {
            try await TestValues.keyVault(transport).list()
        }
    }

    @Test func readValueScansTheBody() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("keyvault/secret-get.json"), method: .get, pathPrefix: "/secrets/DATABASE-URL")
        let item = TestValues.item(remoteName: "DATABASE-URL", name: "DATABASE_URL")
        let value = try await TestValues.keyVault(transport).readValue(of: item)
        #expect(value.testText == "fixture \"quoted\" value\nété 🚀 /end")
        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://kv-sample-prod.vault.azure.net/secrets/DATABASE-URL?api-version=7.4")
    }

    @Test func readValueRefusesUnreadableItems() async throws {
        let transport = FakeHTTPTransport()
        let item = TestValues.item(remoteName: "OLD-FLAG", name: "OLD_FLAG", isValueReadable: false)
        await #expect(throws: DestinationError.invalidRequest(code: DestinationError.LocalCode.writeOnly)) {
            try await TestValues.keyVault(transport).readValue(of: item)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func setValuePutsOnlyTheValue() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("keyvault/secret-set.json"), method: .put, pathPrefix: "/secrets/DATABASE-URL")
        let value = "fixture-value-new-\(UUID().uuidString)"
        let result = try await TestValues.keyVault(transport).setValue(TestValues.secret(value), name: "DATABASE_URL", kind: .variable, existing: nil)
        #expect(result == RemoteWriteResultModel(version: "1790000500"))

        let request = try #require(transport.requests.first)
        #expect(request.method == .put)
        #expect(request.url.absoluteString == "https://kv-sample-prod.vault.azure.net/secrets/DATABASE-URL?api-version=7.4")
        #expect(request.bodyText == "{\"value\":\"\(value)\"}")
        #expect(request.headerNames == ["accept", "content-type", "authorization"])
        expectValueOnlyInBodies(transport.requests, value: value)
    }

    @Test func setValueWritesToTheExistingRemoteName() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("keyvault/secret-set.json"))
        let existing = TestValues.item(remoteName: "api-url", name: "API_URL")
        _ = try await TestValues.keyVault(transport).setValue(TestValues.secret("v"), name: "API_URL", kind: .secret, existing: existing)
        #expect(transport.requests.first?.path == "/secrets/api-url")
    }

    @Test func setValueEscapesTheValue() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("keyvault/secret-set.json"))
        _ = try await TestValues.keyVault(transport).setValue(TestValues.secret(TestValues.trickyValue), name: "NOTE", kind: .secret, existing: nil)
        let body = try #require(try transport.requests.first?.bodyJSON() as? [String: String])
        #expect(body == ["value": TestValues.trickyValue])
    }

    @Test func setValueRecoversASoftDeletedName() async throws {
        let transport = FakeHTTPTransport()
        let clock = InstantClock()
        transport.enqueue(try Fixture.response("keyvault/error-deleted-recoverable.json", status: 409), method: .put)
        transport.enqueue(try Fixture.response("keyvault/secret-recover.json"), method: .post, pathPrefix: "/deletedsecrets/DATABASE-URL/recover")
        transport.enqueue(try Fixture.response("keyvault/error-not-found.json", status: 404), method: .get)
        transport.enqueue(try Fixture.response("keyvault/error-not-found.json", status: 404), method: .get)
        transport.enqueue(try Fixture.response("keyvault/secret-get.json"), method: .get)
        transport.enqueue(try Fixture.response("keyvault/secret-set.json"), method: .put)
        let value = "fixture-recovered-value"
        let result = try await TestValues.keyVault(transport, clock: clock)
            .setValue(TestValues.secret(value), name: "DATABASE_URL", kind: .secret, existing: nil)
        #expect(result.version == "1790000500")

        let shape = transport.requests.map { "\($0.method.rawValue) \($0.path)" }
        #expect(shape == [
            "PUT /secrets/DATABASE-URL",
            "POST /deletedsecrets/DATABASE-URL/recover",
            "GET /secrets/DATABASE-URL",
            "GET /secrets/DATABASE-URL",
            "GET /secrets/DATABASE-URL",
            "PUT /secrets/DATABASE-URL",
        ])
        #expect(transport.requests[1].body == nil)
        #expect(transport.requests[1].query == "api-version=7.4")
        #expect(transport.requests.filter { $0.method == .put }.allSatisfy { $0.bodyText == "{\"value\":\"\(value)\"}" })
        #expect(clock.sleeps == [Timeouts.verifyRetryInterval, Timeouts.verifyRetryInterval])
        #expect(!transport.requests.contains { $0.path.contains("purge") }, "never purges")
        expectValueOnlyInBodies(transport.requests, value: value)
    }

    @Test func recoverPollingGivesUpAfterTheWindow() async throws {
        let transport = FakeHTTPTransport()
        let clock = InstantClock()
        transport.enqueue(try Fixture.response("keyvault/error-deleted-recoverable.json", status: 409), method: .put)
        transport.enqueue(try Fixture.response("keyvault/secret-recover.json"), method: .post)
        transport.stub(.status(404), method: .get)
        transport.enqueue(try Fixture.response("keyvault/error-deleted-recoverable.json", status: 409), method: .put)
        await #expect(throws: DestinationError.deletedButRecoverable) {
            try await TestValues.keyVault(transport, clock: clock)
                .setValue(TestValues.secret("v"), name: "DATABASE_URL", kind: .secret, existing: nil)
        }
        let maxPolls = Int(Timeouts.verifyRetryWindow / Timeouts.verifyRetryInterval)
        #expect(clock.sleeps.count == maxPolls)
        #expect(transport.requests.filter { $0.method == .post }.count == 1, "recovers once")
        #expect(transport.requests.filter { $0.method == .put }.count == 2, "PUT, recover, PUT once more")
    }

    @Test func otherConflictsAreNotRecovered() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("keyvault/error-being-deleted.json", status: 409))
        await #expect(throws: DestinationError.conflict(code: "ObjectIsBeingDeleted")) {
            try await TestValues.keyVault(transport).setValue(TestValues.secret("v"), name: "DATABASE_URL", kind: .secret, existing: nil)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func setValueChecksNameAndSizeBeforeSending() async throws {
        let transport = FakeHTTPTransport()
        let remote = try TestValues.keyVault(transport)
        await #expect(throws: DestinationError.invalidInput(.invalidName(.leadingDigit))) {
            try await remote.setValue(TestValues.secret("v"), name: "1ABC", kind: .secret, existing: nil)
        }
        let tooLarge = SecretBytes(count: Limits.maxKeyVaultValueBytes + 1)
        await #expect(throws: DestinationError.valueTooLarge) {
            try await remote.setValue(tooLarge, name: "BIG", kind: .secret, existing: nil)
        }
        await #expect(throws: DestinationError.valueNotUTF8) {
            try await remote.setValue(SecretBytes(copying: [0xFF]), name: "BINARY", kind: .secret, existing: nil)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func deleteIsASoftDelete() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("keyvault/secret-delete.json"), method: .delete)
        try await TestValues.keyVault(transport).delete(TestValues.item(remoteName: "DATABASE-URL", name: "DATABASE_URL"))
        let request = try #require(transport.requests.first)
        #expect(request.method == .delete)
        #expect(request.url.absoluteString == "https://kv-sample-prod.vault.azure.net/secrets/DATABASE-URL?api-version=7.4")
        #expect(request.body == nil)
    }

    @Test func deleteOfAMissingSecretIsNotFound() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("keyvault/error-not-found.json", status: 404))
        await #expect(throws: DestinationError.notFound) {
            try await TestValues.keyVault(transport).delete(TestValues.item(remoteName: "GONE", name: "GONE"))
        }
    }

    @Test func remoteNamesThatCannotBeAPathAreRefused() async throws {
        let transport = FakeHTTPTransport()
        let remote = try TestValues.keyVault(transport)
        for name in ["..", "a/b", "bad_name", "", "a?b"] {
            await #expect(throws: DestinationError.self) {
                try await remote.delete(TestValues.item(remoteName: name, name: nil))
            }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func errorsMapFromStatus() async throws {
        let cases: [(FakeHTTPTransport.Response, DestinationError)] = [
            (try Fixture.response("keyvault/error-forbidden.json", status: 403), .forbidden),
            (.status(404), .notFound),
            (.status(400), .invalidRequest(code: nil)),
        ]
        for (response, expected) in cases {
            let transport = FakeHTTPTransport()
            transport.stub(response)
            await #expect(throws: expected) {
                try await TestValues.keyVault(transport).list()
            }
        }
    }

    @Test func secretNameFromID() {
        #expect(AzureKeyVaultRemote.secretName(fromID: "https://kv.vault.azure.net/secrets/NAME") == "NAME")
        #expect(AzureKeyVaultRemote.secretName(fromID: "https://kv.vault.azure.net/secrets/NAME/0123abcd") == "NAME")
        #expect(AzureKeyVaultRemote.secretName(fromID: "https://kv.vault.azure.net/keys/NAME") == nil)
        #expect(AzureKeyVaultRemote.secretName(fromID: "not a url") == nil)
    }
}
