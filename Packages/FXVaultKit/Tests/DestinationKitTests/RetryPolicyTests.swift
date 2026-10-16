import Foundation
import Testing
@testable import DestinationKit
import VaultCore

/// Retries, Retry-After and the Key Vault 401 refresh, on an instant clock.
@Suite("Retry policy")
struct RetryPolicyTests {
    private var url: URL {
        get throws { try #require(URL(string: "https://api.vercel.com/v2/user")) }
    }

    private func client(
        _ transport: FakeHTTPTransport,
        clock: InstantClock,
        credential: ProviderCredential? = nil
    ) throws -> ProviderHTTPClient {
        ProviderHTTPClient(
            provider: .vercel,
            transport: transport,
            clock: clock,
            credential: try credential ?? .personalToken(TestValues.secret(TestValues.vercelToken))
        )
    }

    @Test func serverErrorsAreRetriedForIdempotentRequests() async throws {
        let transport = FakeHTTPTransport()
        let clock = InstantClock()
        transport.enqueue(.status(503))
        transport.enqueue(.failure(.network))
        transport.enqueue(.json("{}"))
        let response = try await client(transport, clock: clock).send(.get, try url, retry: .idempotent)
        #expect(response.status == 200)
        #expect(transport.requests.count == 3)
        #expect(clock.sleeps == [Timeouts.idempotentRetryBackoff, Timeouts.idempotentRetryBackoff * 2], "backoff × attempt")
    }

    @Test func retriesStopAfterTheLimit() async throws {
        let transport = FakeHTTPTransport()
        let clock = InstantClock()
        transport.stub(.status(502))
        await #expect(throws: DestinationError.server(status: 502)) {
            try await client(transport, clock: clock).send(.put, try url, retry: .idempotent)
        }
        #expect(transport.requests.count == 1 + Limits.idempotentRetries)
    }

    @Test func timeoutsAreRetriedOnlyWhenIdempotent() async throws {
        let transport = FakeHTTPTransport()
        let clock = InstantClock()
        transport.stub(.failure(.timeout))
        await #expect(throws: DestinationError.timeout) {
            try await client(transport, clock: clock).send(.post, try url, retry: .never)
        }
        #expect(transport.requests.count == 1, "a write that may have applied is never resent")
        #expect(clock.sleeps.isEmpty)
    }

    @Test func nonIdempotentServerErrorIsNotRetried() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(.status(500))
        await #expect(throws: DestinationError.server(status: 500)) {
            try await client(transport, clock: InstantClock()).send(.patch, try url, body: .members(["a": .integer(1)]), retry: .never)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func rateLimitHonorsRetryAfter() async throws {
        let transport = FakeHTTPTransport()
        let clock = InstantClock()
        transport.enqueue(.status(429, headers: ["Retry-After": "7"]))
        transport.enqueue(.status(429))
        transport.enqueue(.json("{}"))
        _ = try await client(transport, clock: clock).send(.get, try url, retry: .idempotent)
        #expect(clock.sleeps == [.seconds(7), Timeouts.destinationRateLimitBackoff])
        #expect(transport.requests.count == 3)
    }

    @Test func rateLimitBeyondTheMaximumStops() async throws {
        let transport = FakeHTTPTransport()
        let clock = InstantClock()
        let tooLong = Timeouts.destinationMaxRetryAfter + .seconds(1)
        transport.stub(.status(429, headers: ["retry-after": String(tooLong.components.seconds)]))
        await #expect(throws: DestinationError.rateLimited(retryAfter: tooLong)) {
            try await client(transport, clock: clock).send(.get, try url, retry: .idempotent)
        }
        #expect(transport.requests.count == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func rateLimitRetriesAreBounded() async throws {
        let transport = FakeHTTPTransport()
        let clock = InstantClock()
        transport.stub(.status(429, headers: ["Retry-After": "1"]))
        await #expect(throws: DestinationError.rateLimited(retryAfter: .seconds(1))) {
            try await client(transport, clock: clock).send(.delete, try url, retry: .idempotent)
        }
        #expect(transport.requests.count == 1 + Limits.rateLimitRetries)
    }

    @Test func rateLimitOnNonIdempotentRequestIsReported() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(.status(429, headers: ["Retry-After": "3"]))
        await #expect(throws: DestinationError.rateLimited(retryAfter: .seconds(3))) {
            try await client(transport, clock: InstantClock()).send(.post, try url, retry: .never)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func keyVault401RefreshesTheTokenOnce() async throws {
        let transport = FakeHTTPTransport()
        let tokens = FakeAccessTokenProvider(tokens: [TestValues.azureToken, TestValues.refreshedAzureToken])
        transport.enqueue(try Fixture.response("keyvault/error-unauthorized.json", status: 401))
        transport.enqueue(.json("{}"))
        let client = ProviderHTTPClient(
            provider: .azureKeyVault,
            transport: transport,
            clock: InstantClock(),
            credential: .azure(tokens, tenantID: TestValues.tenantID)
        )
        let kvURL = try #require(URL(string: "https://kv-sample-prod.vault.azure.net/secrets?api-version=7.4"))
        _ = try await client.send(.post, kvURL, retry: .never)
        #expect(transport.requests.map(\.bearerToken) == [TestValues.azureToken, TestValues.refreshedAzureToken])
        #expect(await tokens.invalidatedTenants == [TestValues.tenantID])
        #expect(await tokens.requestedTenants == [TestValues.tenantID, TestValues.tenantID])
    }

    @Test func keyVaultSecond401IsUnauthorized() async throws {
        let transport = FakeHTTPTransport()
        let tokens = FakeAccessTokenProvider()
        transport.stub(.status(401))
        let client = ProviderHTTPClient(provider: .azureKeyVault, transport: transport, clock: InstantClock(), credential: .azure(tokens, tenantID: nil))
        let kvURL = try #require(URL(string: "https://kv-sample-prod.vault.azure.net/secrets?api-version=7.4"))
        await #expect(throws: DestinationError.unauthorized) {
            try await client.send(.get, kvURL, retry: .idempotent)
        }
        #expect(transport.requests.count == 2)
        #expect(await tokens.invalidatedTenants == [nil])
    }

    @Test func personalToken401IsNotRetried() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(.status(401))
        await #expect(throws: DestinationError.unauthorized) {
            try await client(transport, clock: InstantClock()).send(.get, try url, retry: .idempotent)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func tokenProviderFailureStopsBeforeSending() async throws {
        let transport = FakeHTTPTransport()
        let tokens = FakeAccessTokenProvider(failure: .azNotSignedIn)
        let client = ProviderHTTPClient(provider: .azureKeyVault, transport: transport, clock: InstantClock(), credential: .azure(tokens, tenantID: nil))
        let kvURL = try #require(URL(string: "https://kv-sample-prod.vault.azure.net/secrets?api-version=7.4"))
        await #expect(throws: DestinationError.azNotSignedIn) {
            try await client.send(.get, kvURL, retry: .idempotent)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func requestHeadersAndBodyEncoding() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(.json("{}"))
        _ = try await client(transport, clock: InstantClock()).send(.post, try url, body: .members(["value": .secret(TestValues.secret("v"))]), retry: .never)
        _ = try await client(transport, clock: InstantClock()).send(.get, try url, retry: .idempotent)
        let post = try #require(transport.requests.first)
        #expect(post.headerNames == ["accept", "content-type", "authorization"])
        #expect(post.headers["Content-Type"] == "application/json")
        #expect(post.bodyText == #"{"value":"v"}"#)
        let get = try #require(transport.requests.last)
        #expect(get.headerNames == ["accept", "authorization"], "no Content-Type without a body")
        #expect(get.body == nil)
    }

    @Test func cancellationStopsTheLoop() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(.status(503))
        let client = try client(transport, clock: InstantClock())
        let url = try url
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(.get, url, retry: .idempotent)
        }
        await #expect(throws: DestinationError.cancelled) {
            try await task.value
        }
        #expect(transport.requests.isEmpty)
    }
}
