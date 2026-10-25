import Foundation
import os
import Testing
@testable import DestinationKit
import VaultCore

/// Hand-written fixtures in `Tests/DestinationKitTests/Fixtures`, following each provider's
/// documented format with synthetic names (tasks/lessons.md: no real identifiers).
enum Fixture {
    struct Missing: Error {
        let path: String
    }

    static func data(_ path: String) throws -> Data {
        guard let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw Missing(path: "Fixtures")
        }
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Missing(path: path) }
        return try Data(contentsOf: url)
    }

    static func string(_ path: String) throws -> String {
        String(decoding: try data(path), as: UTF8.self)
    }

    /// A fake response with the fixture as its JSON body.
    static func response(_ path: String, status: Int = 200, headers: [String: String] = [:]) throws -> FakeHTTPTransport.Response {
        FakeHTTPTransport.Response(status: status, headers: headers, body: try data(path))
    }
}

/// A clock whose sleeps return at once after moving time forward; every sleep is recorded.
final class InstantClock: VaultClock {
    private struct State: Sendable {
        var now: Date
        var uptime: Duration = .zero
        var sleeps: [Duration] = []
    }

    static let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let state: OSAllocatedUnfairLock<State>

    init(now: Date = InstantClock.start) {
        state = OSAllocatedUnfairLock(initialState: State(now: now))
    }

    var now: Date {
        state.withLock { $0.now }
    }

    var uptime: Duration {
        state.withLock { $0.uptime }
    }

    var sleeps: [Duration] {
        state.withLock { $0.sleeps }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock { state in
            state.sleeps.append(duration)
            state.uptime += duration
            state.now = state.now.addingTimeInterval(duration.timeInterval)
        }
    }

    /// Moves wall time only (token expiry tests).
    func advanceWallClock(by seconds: TimeInterval) {
        state.withLock { $0.now = $0.now.addingTimeInterval(seconds) }
    }
}

/// A scripted ``AccessTokenProviding``: hands out `tokens` in order (the last one repeats) and
/// records each request and invalidation.
actor FakeAccessTokenProvider: AccessTokenProviding {
    private let tokens: [String]
    private var next = 0
    private(set) var requestedTenants: [String?] = []
    private(set) var invalidatedTenants: [String?] = []
    private let failure: DestinationError?

    init(tokens: [String] = [TestValues.azureToken], failure: DestinationError? = nil) {
        self.tokens = tokens
        self.failure = failure
    }

    func token(tenantID: String?) async throws(DestinationError) -> SecretBytes {
        requestedTenants.append(tenantID)
        if let failure { throw failure }
        let token = tokens[min(next, tokens.count - 1)]
        next += 1
        return SecretBytes(utf8: token)
    }

    func invalidate(tenantID: String?) async {
        invalidatedTenants.append(tenantID)
    }
}

/// Synthetic identifiers and values. Token-shaped strings are assembled at runtime so no token
/// literal is in source.
enum TestValues {
    static let vaultName = "kv-sample-prod"
    static let vaultHost = "kv-sample-prod.vault.azure.net"
    static let tenantID = "00000000-0000-0000-0000-000000000001"
    static let azureToken = syntheticToken("az", filler: "a")
    static let refreshedAzureToken = syntheticToken("az", filler: "b")
    /// A value with every kind of character a JSON body must handle.
    static let trickyValue = "fixture \"quoted\" \\ back\nline\ttab\u{01}ctl é 🚀 /end"

    private static func syntheticToken(_ prefix: String, filler: Character) -> String {
        [prefix, "fixture", String(repeating: filler, count: 24)].joined(separator: "-")
    }

    static func secret(_ text: String) -> SecretBytes {
        SecretBytes(utf8: text)
    }

    static func remoteFactory(
        _ transport: FakeHTTPTransport,
        tokens: FakeAccessTokenProvider = FakeAccessTokenProvider(),
        clock: InstantClock = InstantClock()
    ) -> DestinationRemoteFactory {
        DestinationRemoteFactory(transport: transport, azureTokens: tokens, clock: clock)
    }

    static func keyVault(
        _ transport: FakeHTTPTransport,
        tokens: FakeAccessTokenProvider = FakeAccessTokenProvider(),
        clock: InstantClock = InstantClock(),
        tenantID: String? = TestValues.tenantID
    ) throws -> any DestinationRemoting {
        try remoteFactory(transport, tokens: tokens, clock: clock)
            .remote(for: .azureKeyVault(vaultName: vaultName, tenantID: tenantID))
    }

    /// A listed item for write and delete tests.
    static func item(
        remoteName: String,
        name: String?,
        kind: ConfigKind = .secret,
        isValueReadable: Bool = true
    ) -> RemoteDestinationItemModel {
        RemoteDestinationItemModel(
            remoteName: remoteName,
            name: name,
            unusableReason: nil,
            kind: kind,
            version: nil,
            isValueReadable: isValueReadable,
            updatedAt: nil
        )
    }
}

extension FakeHTTPTransport.RecordedRequest {
    /// The body parsed as JSON (test data).
    func bodyJSON() throws -> Any {
        try JSONSerialization.jsonObject(with: try #require(body), options: [.fragmentsAllowed])
    }
}

/// Asserts that `value` appears in no URL, header or token of `requests` (values travel only in
/// bodies).
func expectValueOnlyInBodies(_ requests: [FakeHTTPTransport.RecordedRequest], value: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    for request in requests {
        let url = request.url.absoluteString
        #expect(!url.contains(value) && !url.contains(encodedValue), "value in URL", sourceLocation: sourceLocation)
        for headerValue in request.headers.values {
            #expect(!headerValue.contains(value), "value in a header", sourceLocation: sourceLocation)
        }
        #expect(request.bearerToken?.contains(value) != true, "value in the token", sourceLocation: sourceLocation)
    }
}

extension SecretBytes {
    /// The bytes as text (tests only).
    var testText: String {
        withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    }
}
