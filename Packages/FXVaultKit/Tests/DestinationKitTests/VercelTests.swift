import Foundation
import Testing
@testable import DestinationKit
import VaultCore

/// Vercel REST API (project environment variables) through ``FakeHTTPTransport``.
@Suite("Vercel")
struct VercelTests {
    private static let envPath = "/v10/projects/prj_sample/env"

    // MARK: - list

    @Test func listKeepsOnlyThisEnvironmentWithReasons() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/env-list.json"), method: .get, pathPrefix: Self.envPath)
        let items = try await TestValues.vercel(transport).list()

        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://api.vercel.com/v10/projects/prj_sample/env?teamId=team_sample")
        #expect(request.bearerToken == TestValues.vercelToken)
        #expect(!request.url.absoluteString.contains("decrypt"), "values are never decrypted in a listing")

        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.remoteName, $0) })
        #expect(items.map(\.remoteName) == [
            "DATABASE_URL", "NEXT_PUBLIC_API_URL", "SIGNING_KEY", "VERCEL_URL", "FEATURE_FLAG", "CUSTOM_SHARED",
            "my-dashed-name", "CONFIG_VALUE",
        ], "PREVIEW_ONLY, BRANCH_ONLY (preview) and CUSTOM_ONLY are not production's")

        let database = try #require(byKey["DATABASE_URL"])
        #expect(database.name == "DATABASE_URL" && database.isUsable)
        #expect(database.kind == .secret)
        #expect(database.remoteRef == "env_database")
        #expect(database.version == "1790000000123")
        #expect(database.updatedAt == Date(timeIntervalSince1970: 1_790_000_000.123))
        #expect(database.otherTargets == [.preview])
        #expect(database.isValueReadable)
        #expect(database.digest == nil)

        #expect(byKey["NEXT_PUBLIC_API_URL"]?.kind == .variable)
        #expect(byKey["NEXT_PUBLIC_API_URL"]?.otherTargets == [])
        #expect(byKey["SIGNING_KEY"]?.kind == .secret)
        #expect(byKey["SIGNING_KEY"]?.isValueReadable == false, "sensitive values are write-only")
        #expect(byKey["SIGNING_KEY"]?.otherTargets == [.preview, .development])
        #expect(byKey["VERCEL_URL"]?.unusableReason == .system)
        #expect(byKey["VERCEL_URL"]?.isValueReadable == false)
        #expect(byKey["FEATURE_FLAG"]?.isUsable == true, "a string target counts")
        #expect(byKey["CUSTOM_SHARED"]?.unusableReason == .customEnvironment)
        #expect(byKey["my-dashed-name"]?.unusableReason == .invalidName(.invalidName(.notUppercase)))
        #expect(byKey["my-dashed-name"]?.name == nil)
        #expect(byKey["CONFIG_VALUE"]?.kind == .variable, "visibility decides when present")
    }

    @Test func previewListsGitBranchVariablesAsUnusable() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/env-list.json"))
        let items = try await TestValues.vercel(transport, environment: .preview).list()
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.remoteName, $0) })
        #expect(byKey["BRANCH_ONLY"]?.unusableReason == .gitBranch)
        #expect(byKey["PREVIEW_ONLY"]?.isUsable == true)
        #expect(byKey["DATABASE_URL"]?.otherTargets == [.production])
        #expect(byKey["NEXT_PUBLIC_API_URL"] == nil)
    }

    @Test func listFollowsPaginationWithUntil() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/env-list-page1.json"))
        transport.enqueue(try Fixture.response("vercel/env-list-page2.json"))
        let items = try await TestValues.vercel(transport, teamID: nil).list()
        #expect(items.map(\.remoteName) == ["PAGE_ONE", "PAGE_TWO"])
        #expect(transport.requests.map(\.url.absoluteString) == [
            "https://api.vercel.com/v10/projects/prj_sample/env",
            "https://api.vercel.com/v10/projects/prj_sample/env?until=1789999999999",
        ], "no teamId for a personal account")
    }

    @Test func paginationThatRepeatsStops() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(try Fixture.response("vercel/env-list-page1.json"))
        let items = try await TestValues.vercel(transport).list()
        #expect(items.map(\.remoteName) == ["PAGE_ONE"])
        #expect(transport.requests.count == 2, "a page with nothing new ends the listing")
    }

    @Test func listAcceptsABareArray() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/env-list-array.json"))
        let items = try await TestValues.vercel(transport, environment: .development).list()
        #expect(items.map(\.remoteName) == ["DEBUG_LEVEL"])
        #expect(items.first?.kind == .variable)
    }

    @Test func hiddenProductionVariablesAreForbidden() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(try Fixture.response("vercel/env-list-hidden.json"))
        await #expect(throws: DestinationError.forbidden) {
            try await TestValues.vercel(transport).list()
        }
        let preview = try await TestValues.vercel(transport, environment: .preview).list()
        #expect(preview.isEmpty, "other environments are complete")
    }

    @Test func listOfSomethingElseIsMalformed() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(.json(#"{"error":null}"#))
        await #expect(throws: DestinationError.decoding) {
            try await TestValues.vercel(transport).list()
        }
    }

    // MARK: - readValue

    @Test func readValueUsesTheDecryptEndpoint() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/env-decrypted.json"), method: .get, pathPrefix: "/v1/projects/prj_sample/env/env_database")
        let item = TestValues.item(remoteName: "DATABASE_URL", name: "DATABASE_URL", remoteRef: "env_database")
        let value = try await TestValues.vercel(transport).readValue(of: item)
        #expect(value.testText == "fixture-value-1 \\ end")
        #expect(transport.requests.first?.url.absoluteString == "https://api.vercel.com/v1/projects/prj_sample/env/env_database?teamId=team_sample")
    }

    @Test func readValueRefusesCiphertextAndWriteOnlyValues() async throws {
        let item = TestValues.item(remoteName: "DATABASE_URL", name: "DATABASE_URL", remoteRef: "env_database")
        let notDecrypted = FakeHTTPTransport()
        notDecrypted.stub(try Fixture.response("vercel/env-not-decrypted.json"))
        await #expect(throws: DestinationError.decoding) {
            try await TestValues.vercel(notDecrypted).readValue(of: item)
        }
        let sensitive = FakeHTTPTransport()
        sensitive.stub(.json(#"{"type":"sensitive","key":"DATABASE_URL","decrypted":false}"#))
        await #expect(throws: DestinationError.invalidRequest(code: DestinationError.LocalCode.writeOnly)) {
            try await TestValues.vercel(sensitive).readValue(of: item)
        }
        let unreadable = FakeHTTPTransport()
        await #expect(throws: DestinationError.invalidRequest(code: DestinationError.LocalCode.writeOnly)) {
            try await TestValues.vercel(unreadable).readValue(of: TestValues.item(remoteName: "S", name: "S", remoteRef: "env_s", isValueReadable: false))
        }
        await #expect(throws: DestinationError.invalidRequest(code: DestinationError.LocalCode.missingRemoteRef)) {
            try await TestValues.vercel(unreadable).readValue(of: TestValues.item(remoteName: "S", name: "S", remoteRef: nil))
        }
        await #expect(throws: DestinationError.invalidRequest(code: DestinationError.LocalCode.missingRemoteRef)) {
            try await TestValues.vercel(unreadable).readValue(of: TestValues.item(remoteName: "S", name: "S", remoteRef: ".."))
        }
        #expect(unreadable.requests.isEmpty)
    }

    // MARK: - setValue

    @Test func newSecretIsAnUpsertingPost() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/env-create.json", status: 201), method: .post, pathPrefix: Self.envPath)
        let value = "fixture-vercel-value"
        let result = try await TestValues.vercel(transport).setValue(TestValues.secret(value), name: "NEW_SECRET", kind: .secret, existing: nil)
        #expect(result == RemoteWriteResultModel(version: "1790000100000", remoteRef: "env_created"))
        let request = try #require(transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://api.vercel.com/v10/projects/prj_sample/env?upsert=true&teamId=team_sample")
        #expect(request.bodyText == "{\"key\":\"NEW_SECRET\",\"value\":\"\(value)\",\"type\":\"encrypted\",\"target\":[\"production\"]}")
        expectValueOnlyInBodies(transport.requests, value: value)
    }

    @Test func newVariableIsPlainAndCreatedMayBeAnArray() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/env-create-array.json", status: 201))
        let result = try await TestValues.vercel(transport, environment: .preview).setValue(TestValues.secret("x"), name: "NEW_VARIABLE", kind: .variable, existing: nil)
        #expect(result == RemoteWriteResultModel(version: "1790000200000", remoteRef: "env_created_array"))
        #expect(transport.requests.first?.bodyText == #"{"key":"NEW_VARIABLE","value":"x","type":"plain","target":["preview"]}"#)
    }

    @Test func failedArrayIsAnError() async throws {
        let exists = FakeHTTPTransport()
        exists.enqueue(try Fixture.response("vercel/env-create-failed.json", status: 201))
        await #expect(throws: DestinationError.conflict(code: "ENV_ALREADY_EXISTS")) {
            try await TestValues.vercel(exists).setValue(TestValues.secret("v"), name: "NEW_SECRET", kind: .secret, existing: nil)
        }
        let other = FakeHTTPTransport()
        other.enqueue(try Fixture.response("vercel/env-create-failed-other.json", status: 201))
        await #expect(throws: DestinationError.invalidRequest(code: "env_value_invalid_type")) {
            try await TestValues.vercel(other).setValue(TestValues.secret("v"), name: "NEW_SECRET", kind: .secret, existing: nil)
        }
        #expect(other.requests.count == 1, "a POST is never resent")
    }

    @Test func createdMissingIsMalformed() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(.json(#"{"failed":[]}"#, status: 201))
        await #expect(throws: DestinationError.decoding) {
            try await TestValues.vercel(transport).setValue(TestValues.secret("v"), name: "A", kind: .secret, existing: nil)
        }
    }

    @Test func existingVariableIsPatchedById() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/env-patch.json"), method: .patch, pathPrefix: "/v9/projects/prj_sample/env/env_database")
        let existing = TestValues.item(remoteName: "DATABASE_URL", name: "DATABASE_URL", remoteRef: "env_database", otherTargets: [.preview])
        let value = "fixture-patched-value"
        let result = try await TestValues.vercel(transport).setValue(TestValues.secret(value), name: "DATABASE_URL", kind: .secret, existing: existing)
        #expect(result == RemoteWriteResultModel(version: "1790000999000", remoteRef: "env_database"))
        let request = try #require(transport.requests.first)
        #expect(request.method == .patch)
        #expect(request.url.absoluteString == "https://api.vercel.com/v9/projects/prj_sample/env/env_database?teamId=team_sample")
        #expect(request.bodyText == "{\"value\":\"\(value)\",\"type\":\"encrypted\"}")
        expectValueOnlyInBodies(transport.requests, value: value)
    }

    @Test func sensitiveStaysSensitive() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/env-patch.json"))
        let existing = TestValues.item(remoteName: "SIGNING_KEY", name: "SIGNING_KEY", remoteRef: "env_signing", isValueReadable: false)
        _ = try await TestValues.vercel(transport).setValue(TestValues.secret("v"), name: "SIGNING_KEY", kind: .secret, existing: existing)
        #expect(transport.requests.first?.bodyText == #"{"value":"v","type":"sensitive"}"#)
    }

    @Test func patchIsNotRetried() async throws {
        let transport = FakeHTTPTransport()
        transport.stub(.status(500))
        let existing = TestValues.item(remoteName: "A", name: "A", remoteRef: "env_a")
        await #expect(throws: DestinationError.server(status: 500)) {
            try await TestValues.vercel(transport).setValue(TestValues.secret("v"), name: "A", kind: .secret, existing: existing)
        }
        #expect(transport.requests.count == 1)
    }

    // MARK: - delete

    @Test func deleteOfASingleTargetVariable() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(.json("{}"), method: .delete, pathPrefix: "/v9/projects/prj_sample/env/env_api_url")
        try await TestValues.vercel(transport).delete(TestValues.item(remoteName: "NEXT_PUBLIC_API_URL", name: "NEXT_PUBLIC_API_URL", kind: .variable, remoteRef: "env_api_url"))
        let request = try #require(transport.requests.first)
        #expect(request.method == .delete)
        #expect(request.url.absoluteString == "https://api.vercel.com/v9/projects/prj_sample/env/env_api_url?teamId=team_sample")
        #expect(request.body == nil)
    }

    @Test func deleteOfAMultiTargetVariableBecomesAPatch() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/env-patch.json"), method: .patch, pathPrefix: "/v9/projects/prj_sample/env/env_signing")
        let item = TestValues.item(remoteName: "SIGNING_KEY", name: "SIGNING_KEY", remoteRef: "env_signing", otherTargets: [.preview, .development])
        try await TestValues.vercel(transport).delete(item)
        let request = try #require(transport.requests.first)
        #expect(request.method == .patch)
        #expect(request.bodyText == #"{"target":["preview","development"]}"#, "only this environment is removed")
        #expect(!transport.requests.contains { $0.method == .delete })
    }

    @Test func deleteNeedsTheRemoteRef() async throws {
        let transport = FakeHTTPTransport()
        await #expect(throws: DestinationError.invalidRequest(code: DestinationError.LocalCode.missingRemoteRef)) {
            try await TestValues.vercel(transport).delete(TestValues.item(remoteName: "A", name: "A"))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func statusErrors() async throws {
        let cases: [(FakeHTTPTransport.Response, DestinationError)] = [
            (.status(401), .unauthorized),
            (try Fixture.response("vercel/error-forbidden.json", status: 403), .forbidden),
            (.status(404), .notFound),
            (.status(402), .forbidden),
        ]
        for (response, expected) in cases {
            let transport = FakeHTTPTransport()
            transport.stub(response)
            await #expect(throws: expected) {
                try await TestValues.vercel(transport).list()
            }
        }
    }

    // MARK: - Account client

    @Test func user() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/user.json"), method: .get, pathPrefix: "/v2/user")
        let user = try await VercelAccountClient(transport: transport, clock: InstantClock()).user(token: TestValues.secret(TestValues.vercelToken))
        #expect(user == VercelUserModel(id: "user_sample", username: "user-a", defaultTeamID: "team_sample"))
        #expect(transport.requests.first?.url.absoluteString == "https://api.vercel.com/v2/user")
    }

    @Test func teamsFollowPagination() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/teams-page1.json"))
        transport.enqueue(try Fixture.response("vercel/teams-page2.json"))
        let teams = try await VercelAccountClient(transport: transport, clock: InstantClock()).teams(token: TestValues.secret(TestValues.vercelToken))
        #expect(teams == [
            VercelTeamModel(id: "team_sample", slug: "example-org", name: "Example Org"),
            VercelTeamModel(id: "team_other", slug: "example-org-b", name: nil),
        ])
        #expect(transport.requests.map(\.url.absoluteString) == [
            "https://api.vercel.com/v2/teams?limit=100",
            "https://api.vercel.com/v2/teams?limit=100&until=1700000000000",
        ])
    }

    @Test func projectsFollowTimestampsAndContinuationTokens() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/projects-page1.json"))
        transport.enqueue(try Fixture.response("vercel/projects-page2-token.json"))
        transport.enqueue(try Fixture.response("vercel/projects-page3.json"))
        let projects = try await VercelAccountClient(transport: transport, clock: InstantClock())
            .projects(token: TestValues.secret(TestValues.vercelToken), teamID: TestValues.vercelTeamID)
        #expect(projects == [
            VercelProjectModel(id: "prj_sample", name: "sample-web"),
            VercelProjectModel(id: "prj_second", name: "sample-docs"),
            VercelProjectModel(id: "prj_third", name: "sample-api"),
        ])
        #expect(transport.requests.map(\.url.absoluteString) == [
            "https://api.vercel.com/v10/projects?limit=100&teamId=team_sample",
            "https://api.vercel.com/v10/projects?limit=100&until=1790000000000&teamId=team_sample",
            "https://api.vercel.com/v10/projects?limit=100&from=FIXTURE%2BCONTINUATION%2FTOKEN%3D&teamId=team_sample",
        ])
    }

    @Test func projectsAsABareArray() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(try Fixture.response("vercel/projects-array.json"))
        let projects = try await VercelAccountClient(transport: transport, clock: InstantClock())
            .projects(token: TestValues.secret(TestValues.vercelToken), teamID: nil)
        #expect(projects == [VercelProjectModel(id: "prj_personal", name: "personal-site")])
        #expect(transport.requests.first?.url.absoluteString == "https://api.vercel.com/v10/projects?limit=100")
    }

    @Test func projectsRefuseABadTeamID() async throws {
        let transport = FakeHTTPTransport()
        await #expect(throws: DestinationError.invalidInput(.invalidDestinationTarget(.vercelTeam))) {
            try await VercelAccountClient(transport: transport, clock: InstantClock()).projects(token: TestValues.secret(TestValues.vercelToken), teamID: "team/../x")
        }
        #expect(transport.requests.isEmpty)
    }
}
