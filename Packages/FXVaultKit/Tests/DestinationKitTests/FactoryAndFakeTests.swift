import Foundation
import Testing
@testable import DestinationKit
import VaultCore

/// ``DestinationRemoteFactory`` and ``FakeHTTPTransport`` itself.
@Suite("Factory and fake transport")
struct FactoryAndFakeTests {
    @Test func factoryBuildsKeyVault() throws {
        let factory = TestValues.remoteFactory(FakeHTTPTransport())
        #expect(try factory.remote(for: .azureKeyVault(vaultName: TestValues.vaultName, tenantID: nil)).provider == .azureKeyVault)
    }

    @Test func factoryValidatesTargets() {
        let factory = TestValues.remoteFactory(FakeHTTPTransport())
        #expect(throws: DestinationError.invalidInput(.invalidDestinationTarget(.keyVaultName))) {
            try factory.remote(for: .azureKeyVault(vaultName: "evil.example/x", tenantID: nil))
        }
        #expect(throws: DestinationError.invalidInput(.invalidDestinationTarget(.tenantID))) {
            try factory.remote(for: .azureKeyVault(vaultName: TestValues.vaultName, tenantID: "--flag"))
        }
    }

    @Test func keyVaultTenantReachesTheTokenProvider() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(.json(#"{"value":[]}"#))
        let tokens = FakeAccessTokenProvider()
        _ = try await TestValues.keyVault(transport, tokens: tokens, tenantID: "example-org.onmicrosoft.com").list()
        #expect(await tokens.requestedTenants == ["example-org.onmicrosoft.com"])
        #expect(transport.requests.first?.url.host == "kv-sample-prod.vault.azure.net")
    }

    // MARK: - FakeHTTPTransport

    @Test func fakeMatchesQueueThenStubs() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(.status(204), method: .get, pathPrefix: "/secrets")
        transport.enqueue(.status(201), method: .get, pathPrefix: "/secrets/A")
        transport.enqueue(.status(202), method: .post)
        let user = try #require(URL(string: "https://kv-sample-prod.vault.azure.net/secrets/A"))
        #expect(try await transport.send(HTTPRequestModel(method: .get, url: user)).status == 201)
        #expect(try await transport.send(HTTPRequestModel(method: .get, url: user)).status == 204, "the queue entry was used once")
        #expect(try await transport.send(HTTPRequestModel(method: .post, url: user)).status == 202)
    }

    @Test func fakeMatchesHost() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(.status(200), host: "kv-other-vault.vault.azure.net")
        let vault = try #require(URL(string: "https://kv-sample-prod.vault.azure.net/secrets"))
        await #expect(throws: DestinationError.invalidRequest(code: DestinationError.LocalCode.fakeUnmatched)) {
            try await transport.send(HTTPRequestModel(method: .get, url: vault))
        }
        #expect(transport.unmatchedRequests.count == 1)
        #expect(transport.requests.count == 1, "unmatched requests are recorded too")
    }

    @Test func fakeRecordsRequestsAndRefusesForeignHosts() async throws {
        let transport = FakeHTTPTransport()
        transport.respond(method: .put) { request in
            .json(#"{"echo":"\#(request.headers["Accept"] ?? "")"}"#)
        }
        let url = try #require(URL(string: "https://kv-sample-prod.vault.azure.net/secrets/A?api-version=7.4"))
        let response = try await transport.send(HTTPRequestModel(
            method: .put,
            url: url,
            headers: ["Accept": "application/json"],
            bearerToken: TestValues.secret(TestValues.azureToken),
            body: TestValues.secret("fixture-body")
        ))
        #expect(response.body.testText == #"{"echo":"application/json"}"#)
        let recorded = try #require(transport.requests.first)
        #expect(recorded.headerNames == ["accept", "authorization"])
        #expect(recorded.bearerToken == TestValues.azureToken)
        #expect(recorded.bodyText == "fixture-body")
        #expect(recorded.path == "/secrets/A")
        #expect(recorded.query == "api-version=7.4")

        let foreign = try #require(URL(string: "https://evil.example/secrets"))
        await #expect(throws: DestinationError.disallowedHost) {
            try await transport.send(HTTPRequestModel(method: .get, url: foreign))
        }
    }

    @Test func fakeFailures() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(.failure(.timeout))
        let url = try #require(URL(string: "https://kv-sample-prod.vault.azure.net/secrets"))
        await #expect(throws: DestinationError.timeout) {
            try await transport.send(HTTPRequestModel(method: .get, url: url))
        }
    }
}
