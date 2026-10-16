import Foundation
import Testing
@testable import DestinationKit
import VaultCore

/// The transport's policy pieces, tested without the network: host allowlist, URL building,
/// request construction, session configuration, redirect refusal, error mapping.
@Suite("HTTP policy")
struct HTTPPolicyTests {
    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    // MARK: - Host allowlist

    @Test(arguments: [
        "https://api.supabase.com/v1/projects",
        "https://api.vercel.com/v10/projects",
        "https://API.Vercel.com/v2/user",
        "https://kv-sample-prod.vault.azure.net/secrets?api-version=7.4",
        "https://kv-sample-prod.vault.azure.net:443/secrets?api-version=7.4&$skiptoken=x",
        "https://abc.vault.azure.net/secrets",
    ])
    func allowedHosts(text: String) throws {
        #expect(DestinationHostPolicy.isAllowed(try url(text)))
    }

    @Test(arguments: [
        "http://api.vercel.com/v2/user",
        "https://api.vercel.com:8443/v2/user",
        "https://user-a@api.vercel.com/v2/user",
        "https://user-a:pw@api.supabase.com/v1/projects",
        "https://api.vercel.com.evil.example/v2/user",
        "https://evil.example/api.vercel.com",
        "https://vercel.com/api",
        "https://api.supabase.co/v1/projects",
        "https://vault.azure.net/secrets",
        "https://ab.vault.azure.net/secrets",
        "https://1kv.vault.azure.net/secrets",
        "https://kv--double.vault.azure.net/secrets",
        "https://kv.sub.vault.azure.net/secrets",
        "https://kv-sample-prod.vault.azure.net.evil.example/secrets",
        "https://kv-sample-prod.vault.azure.cn/secrets",
        "https://127.0.0.1/secrets",
        "file:///etc/passwd",
        "ftp://api.vercel.com/",
    ])
    func refusedHosts(text: String) throws {
        #expect(!DestinationHostPolicy.isAllowed(try url(text)))
    }

    @Test func nextLinkMustStayOnTheVault() throws {
        let origin = try url("https://kv-sample-prod.vault.azure.net/secrets?api-version=7.4")
        #expect(DestinationHostPolicy.isSameAllowedHost(try url("https://KV-SAMPLE-PROD.vault.azure.net:443/secrets?x=1"), as: origin))
        #expect(!DestinationHostPolicy.isSameAllowedHost(try url("https://kv-other-vault.vault.azure.net/secrets"), as: origin))
        #expect(!DestinationHostPolicy.isSameAllowedHost(try url("http://kv-sample-prod.vault.azure.net/secrets"), as: origin))
    }

    // MARK: - URL building

    @Test func providerURLEncodesSegmentsAndQuery() throws {
        let built = try ProviderURL.make(
            host: DestinationConstants.vercelHost,
            segments: ["v10", "projects", "prj_sample", "env"],
            query: [(name: "from", value: "a+b/c=d e"), (name: "teamId", value: "team_sample")]
        )
        #expect(built.absoluteString == "https://api.vercel.com/v10/projects/prj_sample/env?from=a%2Bb%2Fc%3Dd%20e&teamId=team_sample")
    }

    @Test(arguments: ["..", ".", "a/b", "%2E%2E", "a\u{0}b", ""])
    func providerURLRejectsUnsafeSegments(segment: String) {
        #expect(throws: DestinationError.self) {
            try ProviderURL.make(host: DestinationConstants.vercelHost, segments: ["v9", segment])
        }
    }

    @Test func providerURLRejectsUnknownHosts() {
        #expect(throws: DestinationError.disallowedHost) {
            try ProviderURL.make(host: "api.example.invalid", segments: ["v1"])
        }
    }

    // MARK: - Request construction

    @Test func urlRequestCarriesOnlyWhatPolicyAllows() throws {
        let body = TestValues.secret(#"{"value":"v"}"#)
        let request = HTTPRequestModel(
            method: .put,
            url: try url("https://kv-sample-prod.vault.azure.net/secrets/NAME?api-version=7.4"),
            headers: ["Accept": "application/json", "Content-Type": "application/json"],
            bearerToken: TestValues.secret(TestValues.azureToken),
            body: body
        )
        let urlRequest = try URLSessionTransport.makeURLRequest(request)
        #expect(urlRequest.httpMethod == "PUT")
        #expect(urlRequest.value(forHTTPHeaderField: "User-Agent") == "FXVault")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestValues.azureToken)")
        #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(urlRequest.httpShouldHandleCookies == false)
        #expect(urlRequest.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(urlRequest.timeoutInterval == Timeouts.destinationRequest.timeInterval)
        #expect(urlRequest.httpBody == Data(#"{"value":"v"}"#.utf8))
    }

    @Test func urlRequestRefusals() throws {
        let allowed = try url("https://api.vercel.com/v2/user")
        #expect(throws: DestinationError.disallowedHost) {
            try URLSessionTransport.makeURLRequest(HTTPRequestModel(method: .get, url: try url("https://evil.example/v2/user")))
        }
        for header in ["Authorization", "authorization", "User-Agent", "Cookie", "Host", "Content-Length"] {
            #expect(throws: DestinationError.invalidRequest(code: DestinationError.LocalCode.invalidHeader)) {
                try URLSessionTransport.makeURLRequest(HTTPRequestModel(method: .get, url: allowed, headers: [header: "x"]))
            }
        }
        #expect(throws: DestinationError.invalidRequest(code: DestinationError.LocalCode.invalidHeader)) {
            try URLSessionTransport.makeURLRequest(HTTPRequestModel(method: .get, url: allowed, headers: ["X-Note": "a\r\nInjected: 1"]))
        }
        for token in ["", "with space", "line\nbreak", "é"] {
            #expect(throws: DestinationError.tokenMissing) {
                try URLSessionTransport.makeURLRequest(HTTPRequestModel(method: .get, url: allowed, bearerToken: TestValues.secret(token)))
            }
        }
    }

    @Test func requestBodyCopyIsIndependentOfTheCallersBuffer() throws {
        let body = TestValues.secret("fixture-body")
        let data = URLSessionTransport.wipingData(copying: body)
        body.wipe()
        #expect(data == Data("fixture-body".utf8), "the transport owns its copy; wiping the caller's buffer is safe")
        #expect(URLSessionTransport.wipingData(copying: SecretBytes(count: 0)).isEmpty)
    }

    @Test func sessionConfigurationIsEphemeralAndStrict() {
        let configuration = URLSessionTransport.makeConfiguration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == Timeouts.destinationRequest.timeInterval)
        #expect(configuration.timeoutIntervalForResource == Timeouts.destinationRequest.timeInterval)
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
        #expect(configuration.waitsForConnectivity == false)
    }

    @Test func redirectsAreRefused() async throws {
        let delegate = RedirectRefusingDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = try url("https://api.vercel.com/v2/user")
        let task = session.dataTask(with: original)
        let response = try #require(HTTPURLResponse(url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://evil.example/"]))
        let next = await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: try url("https://evil.example/")))
        #expect(next == nil)
        task.cancel()
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, DestinationError.network),
        (.cannotFindHost, .network),
        (.dnsLookupFailed, .network),
        (.networkConnectionLost, .network),
        (.cannotConnectToHost, .network),
        (.secureConnectionFailed, .network),
        (.serverCertificateUntrusted, .network),
        (.serverCertificateHasBadDate, .network),
        (.timedOut, .timeout),
        (.cancelled, .cancelled),
        (.httpTooManyRedirects, .disallowedHost),
        (.appTransportSecurityRequiresSecureConnection, .disallowedHost),
        (.dataLengthExceedsMaximum, .responseTooLarge),
        (.cannotParseResponse, .decoding),
    ])
    func urlErrorMapping(code: URLError.Code, expected: DestinationError) {
        #expect(URLSessionTransport.map(URLError(code)) == expected)
    }

    @Test func responseHeadersAreLowercased() throws {
        let response = try #require(HTTPURLResponse(
            url: try url("https://api.vercel.com/"),
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "5", "X-RateLimit-Reset": "1"]
        ))
        let headers = URLSessionTransport.headers(of: response)
        #expect(headers["retry-after"] == "5")
        let model = HTTPResponseModel(status: 429, headers: ["Retry-After": "5"])
        #expect(model.header("RETRY-AFTER") == "5")
        #expect(model.headers.keys.sorted() == ["retry-after"])
    }

    @Test func descriptionsShowNoURLPathOrBody() throws {
        let request = HTTPRequestModel(
            method: .post,
            url: try url("https://api.vercel.com/v10/projects/prj_sample/env?teamId=team_sample"),
            bearerToken: TestValues.secret(TestValues.vercelToken),
            body: TestValues.secret("fixture-body")
        )
        for text in [String(describing: request), String(reflecting: request), "\(request)"] {
            #expect(!text.contains("prj_sample") && !text.contains("team_sample") && !text.contains("fixture-body"))
            #expect(!text.contains(TestValues.vercelToken))
        }
        let response = HTTPResponseModel(status: 200, body: TestValues.secret("fixture-body"))
        #expect(!String(describing: response).contains("fixture-body"))
    }

    // MARK: - Retry-After and errors

    @Test func retryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(RetryAfter.duration(from: "7", now: now) == .seconds(7))
        #expect(RetryAfter.duration(from: " 0 ", now: now) == .seconds(0))
        #expect(RetryAfter.duration(from: "-1", now: now) == nil)
        #expect(RetryAfter.duration(from: "soon", now: now) == nil)
        #expect(RetryAfter.duration(from: nil, now: now) == nil)
        // 2026-09-21T14:13:20Z is `now`; 30 s later:
        #expect(RetryAfter.duration(from: "Mon, 21 Sep 2026 14:13:50 GMT", now: now) == .seconds(30))
        #expect(RetryAfter.duration(from: "Mon, 21 Sep 2026 14:00:00 GMT", now: now) == .seconds(0), "a past date waits zero")
    }

    @Test func sanitizedCodesKeepIdentifiersOnly() {
        #expect(DestinationError.sanitizedCode("ObjectIsDeletedButRecoverable") == "ObjectIsDeletedButRecoverable")
        #expect(DestinationError.sanitizedCode("ENV_ALREADY_EXISTS") == "ENV_ALREADY_EXISTS")
        #expect(DestinationError.sanitizedCode("a.b-c_d") == "a.b-c_d")
        #expect(DestinationError.sanitizedCode("Bad Parameter") == nil)
        #expect(DestinationError.sanitizedCode("name: DATABASE_URL") == nil)
        #expect(DestinationError.sanitizedCode("") == nil)
        #expect(DestinationError.sanitizedCode(String(repeating: "a", count: 65)) == nil)
        #expect(DestinationError.sanitizedCode("é") == nil)
        #expect(DestinationError.sanitizedCode(nil) == nil)
    }

    @Test func errorProperties() {
        #expect(DestinationError.network.isTransient && DestinationError.timeout.isTransient && DestinationError.server(status: 503).isTransient)
        #expect(!DestinationError.rateLimited(retryAfter: nil).isTransient && !DestinationError.notFound.isTransient)
        #expect(!DestinationError.network.reachedProvider && !DestinationError.timeout.reachedProvider && !DestinationError.cancelled.reachedProvider)
        #expect(!DestinationError.azNotSignedIn.reachedProvider && !DestinationError.tokenMissing.reachedProvider)
        #expect(!DestinationError.invalidRequest(code: DestinationError.LocalCode.writeOnly).reachedProvider)
        #expect(DestinationError.invalidRequest(code: "bad_request").reachedProvider)
        #expect(DestinationError.unauthorized.reachedProvider && DestinationError.conflict(code: nil).reachedProvider)
        #expect(DestinationError.azUntrusted(path: "/Users/user-a/bin/az").logCode == "azUntrusted", "no path in logs")
        #expect(DestinationError.conflict(code: "ENV_ALREADY_EXISTS").logCode == "conflict(ENV_ALREADY_EXISTS)")
        #expect(DestinationError.invalidRequest(code: nil).logCode == "invalidRequest(-)")
        #expect(DestinationError.server(status: 502).logCode == "server(502)")
    }

    @Test(arguments: [
        (400, DestinationProvider.vercel, "", DestinationError.invalidRequest(code: nil)),
        (401, .vercel, "", .unauthorized),
        (402, .vercel, "", .forbidden),
        (403, .vercel, "vercel/error-forbidden.json", .forbidden),
        (403, .vercel, "vercel/error-already-exists.json", .conflict(code: "ENV_ALREADY_EXISTS")),
        (400, .vercel, "vercel/error-already-exists.json", .conflict(code: "ENV_ALREADY_EXISTS")),
        (404, .azureKeyVault, "keyvault/error-not-found.json", .notFound),
        (410, .vercel, "", .notFound),
        (409, .azureKeyVault, "keyvault/error-deleted-recoverable.json", .deletedButRecoverable),
        (409, .azureKeyVault, "keyvault/error-being-deleted.json", .conflict(code: "ObjectIsBeingDeleted")),
        (403, .azureKeyVault, "keyvault/error-forbidden.json", .forbidden),
        (400, .azureKeyVault, "keyvault/error-message-quotes-name.json", .invalidRequest(code: nil)),
        (413, .supabase, "", .valueTooLarge),
        (422, .supabase, "supabase/error-unauthorized.json", .invalidRequest(code: nil)),
        (429, .supabase, "", .rateLimited(retryAfter: nil)),
        (302, .vercel, "", .disallowedHost),
        (500, .vercel, "", .server(status: 500)),
        (503, .azureKeyVault, "", .server(status: 503)),
        (418, .vercel, "", .invalidRequest(code: nil)),
    ])
    func statusMapping(status: Int, provider: DestinationProvider, fixture: String, expected: DestinationError) throws {
        let body = fixture.isEmpty ? SecretBytes(count: 0) : SecretBytes(try Fixture.data(fixture))
        let response = HTTPResponseModel(status: status, body: body)
        #expect(ProviderErrorMapper.error(for: response, provider: provider, now: InstantClock.start) == expected)
        #expect(body.isWiped, "error bodies are wiped once read")
    }

    @Test func errorCodesPreferTheInnermost() throws {
        let body = SecretBytes(try Fixture.data("keyvault/error-forbidden.json"))
        #expect(ProviderErrorMapper.errorCodes(in: body, provider: .azureKeyVault) == ["ForbiddenByRbac", "Forbidden"])
        #expect(ProviderErrorMapper.errorCodes(in: TestValues.secret("not json"), provider: .vercel).isEmpty)
    }
}
