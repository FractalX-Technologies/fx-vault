import Foundation
import Testing
@testable import DestinationKit
import VaultCore

/// Supabase Management API (Edge Function secrets) through ``FakeHTTPTransport``.
@Suite("Supabase")
struct SupabaseTests {
    private static let secretsPath = "/v1/projects/abcdefghijklmnopqrst/secrets"

    @Test func listReadsDigestsAndNames() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("supabase/secrets-list.json"), method: .get, pathPrefix: Self.secretsPath)
        let items = try await TestValues.supabase(transport).list()

        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://api.supabase.com\(Self.secretsPath)")
        #expect(request.bearerToken == TestValues.supabaseToken)
        #expect(request.headerNames == ["accept", "authorization"])

        #expect(items.map(\.remoteName) == ["DATABASE_URL", "SUPABASE_URL", "worker_mode", "1ST_CHOICE"])
        let database = items[0]
        let listed = try #require(try JSONSerialization.jsonObject(with: try Fixture.data("supabase/secrets-list.json")) as? [[String: String]])
        let rawDigest = try #require(listed.first?["value"])
        #expect(rawDigest != rawDigest.lowercased(), "the fixture's digest is uppercase")
        #expect(database.digest == rawDigest.lowercased(), "lowercased")
        #expect(database.version == database.digest)
        #expect(database.kind == .secret)
        #expect(!database.isValueReadable)
        #expect(database.isUsable)
        let updatedAt = try #require(database.updatedAt?.timeIntervalSince1970)
        #expect(abs(updatedAt - 1_790_856_000.123) < 0.001, "fractional seconds are read")
        #expect(items[1].unusableReason == .system, "SUPABASE_ names are Supabase's own")
        // Supabase names are case-sensitive and FX Vault keeps names uppercase: left as it is.
        #expect(items[2].name == nil && !items[2].isUsable)
        #expect(items[2].unusableReason == .invalidName(.invalidName(.notUppercase)))
        #expect(items[2].updatedAt == Date(timeIntervalSince1970: 1_790_856_000))
        #expect(items[3].unusableReason == .invalidName(.invalidName(.leadingDigit)))
        #expect(items[3].updatedAt == nil)
    }

    @Test func listRequiresAnArrayOfNamedSecrets() async throws {
        for body in [#"{"name":"A"}"#, #"[{"value":"x"}]"#, "[1]"] {
            let transport = FakeHTTPTransport()
            transport.stub(.json(body))
            await #expect(throws: DestinationError.decoding) {
                try await TestValues.supabase(transport).list()
            }
        }
    }

    @Test func readValueIsRefused() async throws {
        let transport = FakeHTTPTransport()
        await #expect(throws: DestinationError.invalidRequest(code: DestinationError.LocalCode.writeOnly)) {
            try await TestValues.supabase(transport).readValue(of: TestValues.item(remoteName: "A", name: "A"))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func setValuePostsAnArray() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(.status(201), method: .post, pathPrefix: Self.secretsPath)
        let value = "fixture-supabase-value"
        let result = try await TestValues.supabase(transport).setValue(TestValues.secret(value), name: "DATABASE_URL", kind: .variable, existing: nil)
        #expect(result == RemoteWriteResultModel(version: nil, remoteRef: nil))
        let request = try #require(transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://api.supabase.com\(Self.secretsPath)")
        #expect(request.bodyText == "[{\"name\":\"DATABASE_URL\",\"value\":\"\(value)\"}]")
        #expect(request.headers["Content-Type"] == "application/json")
        expectValueOnlyInBodies(transport.requests, value: value)
    }

    @Test func upsertingPostIsRetried() async throws {
        let transport = FakeHTTPTransport()
        let clock = InstantClock()
        transport.enqueue(.status(502))
        transport.enqueue(.status(201))
        _ = try await TestValues.supabase(transport, clock: clock).setValue(TestValues.secret("v"), name: "A", kind: .secret, existing: nil)
        #expect(transport.requests.count == 2)
        #expect(transport.requests.allSatisfy { $0.bodyText == #"[{"name":"A","value":"v"}]"# }, "the same body on the retry")
    }

    @Test func setValueRefusesReservedNames() async throws {
        let transport = FakeHTTPTransport()
        await #expect(throws: DestinationError.invalidInput(.invalidName(.reservedByProvider))) {
            try await TestValues.supabase(transport).setValue(TestValues.secret("v"), name: "SUPABASE_URL", kind: .secret, existing: nil)
        }
        await #expect(throws: DestinationError.valueTooLarge) {
            try await TestValues.supabase(transport).setValue(SecretBytes(count: Limits.maxValueBytes + 1), name: "BIG", kind: .secret, existing: nil)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func deleteSendsTheNameInTheBody() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(.json("{}"), method: .delete, pathPrefix: Self.secretsPath)
        try await TestValues.supabase(transport).delete(TestValues.item(remoteName: "DATABASE_URL", name: "DATABASE_URL"))
        let request = try #require(transport.requests.first)
        #expect(request.method == .delete)
        #expect(request.url.absoluteString == "https://api.supabase.com\(Self.secretsPath)")
        #expect(request.bodyText == #"["DATABASE_URL"]"#)
    }

    @Test func errors() async throws {
        let cases: [(FakeHTTPTransport.Response, DestinationError)] = [
            (try Fixture.response("supabase/error-unauthorized.json", status: 401), .unauthorized),
            (.status(403), .forbidden),
            (.status(404), .notFound),
            (.status(429), .rateLimited(retryAfter: nil)),
        ]
        for (response, expected) in cases {
            let transport = FakeHTTPTransport()
            transport.stub(response)
            await #expect(throws: expected) {
                try await TestValues.supabase(transport).list()
            }
        }
    }

    @Test func projectsForThePicker() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("supabase/projects.json"), method: .get, pathPrefix: "/v1/projects")
        let projects = try await SupabaseAccountClient(transport: transport, clock: InstantClock())
            .projects(token: TestValues.secret(TestValues.supabaseToken))
        #expect(projects == [
            SupabaseProjectModel(ref: "abcdefghijklmnopqrst", name: "sample-backend", region: "eu-central-1", organizationID: "org-sample-a", status: "ACTIVE_HEALTHY"),
            SupabaseProjectModel(ref: "zyxwvutsrqponmlkjihg", name: "sample-paused", region: "us-east-1", organizationID: "org-sample-b", status: "INACTIVE"),
        ])
        #expect(transport.requests.first?.url.absoluteString == "https://api.supabase.com/v1/projects")
        #expect(transport.requests.first?.bearerToken == TestValues.supabaseToken)
    }

    @Test func projectsRefuseAMissingToken() async throws {
        let transport = FakeHTTPTransport()
        for token in ["", "two words"] {
            await #expect(throws: DestinationError.tokenMissing) {
                try await SupabaseAccountClient(transport: transport, clock: InstantClock()).projects(token: TestValues.secret(token))
            }
        }
        #expect(transport.requests.isEmpty)
    }
}
