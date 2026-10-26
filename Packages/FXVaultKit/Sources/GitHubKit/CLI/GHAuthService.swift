import Foundation
import VaultCore

/// Accounts and tokens through gh (tasks/todo.md §8 A3, A4; §7.3 tokens).
///
/// Neither call sends `GH_TOKEN`. Tokens stay in memory (``GHTokenCache``) and are never
/// logged; every token returned is a copy the caller wipes.
public struct GHAuthService: Sendable {
    private let service: GHCommandService
    public let tokenCache: GHTokenCache

    public init(service: GHCommandService, tokenCache: GHTokenCache) {
        self.service = service
        self.tokenCache = tokenCache
    }

    // MARK: - Commands

    /// A3: `gh auth status --hostname github.com --json hosts`.
    public static func statusCommand() throws(GHError) -> GHCommand {
        try GHCommand(
            operation: .authStatus,
            arguments: ["auth", "status", "--hostname", GHConstants.host, "--json", "hosts"],
            logTemplate: "auth status --hostname github.com --json hosts"
        )
    }

    /// A4: `gh auth token --hostname github.com --user=<login>`.
    public static func tokenCommand(login: String) throws(GHError) -> GHCommand {
        let login = try GHReposCommands.validatedOwner(login)
        return try GHCommand(
            operation: .authToken,
            arguments: ["auth", "token", "--hostname", GHConstants.host, "--user=\(login)"],
            logTemplate: "auth token --hostname github.com --user={login}"
        )
    }

    /// A7 (1.0 B4b): `gh auth refresh -h github.com -s <scopes>`, for gh's active account. The
    /// scopes come from ``GHApprovalScope`` only.
    public static func refreshCommand(scopes: [GHApprovalScope]) throws(GHError) -> GHCommand {
        guard !scopes.isEmpty else { throw .invalidInput(.emptyValue) }
        return try GHCommand(
            operation: .authRefresh,
            arguments: ["auth", "refresh", "-h", GHConstants.host, "-s", scopeList(scopes)],
            logTemplate: "auth refresh -h github.com -s {scopes}"
        )
    }

    /// What the user can run in Terminal instead (shown with Copy when the in-app run fails).
    public static func refreshCommandText(scopes: [GHApprovalScope]) -> String {
        "gh auth refresh -h \(GHConstants.host) -s \(scopeList(scopes))"
    }

    /// In the fixed list's order, each once.
    private static func scopeList(_ scopes: [GHApprovalScope]) -> String {
        GHApprovalScope.allCases.filter(scopes.contains).map(\.rawValue).joined(separator: ",")
    }

    // MARK: - Operations

    /// Runs A7: `onDeviceCode` gets gh's code once it prints it, then gh waits for the approval
    /// in the browser and exits. Without a code within `codeWait`, gh is stopped
    /// (`.unrecognizedOutput`). Cancelling the task ends gh. Nothing of gh's output is kept.
    public func approve(
        scopes: [GHApprovalScope],
        codeWait: Duration = Timeouts.ghDeviceCodeWait,
        onDeviceCode: @escaping @Sendable (GHDeviceCodeModel) -> Void
    ) async throws(GHApprovalError) {
        let command: GHCommand
        do {
            command = try Self.refreshCommand(scopes: scopes)
        } catch {
            throw .failed
        }
        let watcher = GHDeviceCodeWatcher(onCode: onDeviceCode)
        let service = self.service
        let outcome: Result<Void, GHApprovalError> = await withTaskGroup(of: Result<Void, GHApprovalError>?.self) { group in
            group.addTask {
                do throws(GHError) {
                    let output = try await service.execute(command, token: nil, stderrObserver: watcher.receive)
                    output.wipe()
                    return .success(())
                } catch {
                    switch error {
                    case .cancelled: return .failure(.cancelled)
                    case .timeout: return .failure(.timedOut)
                    default: return .failure(watcher.hasCode ? .failed : .unrecognizedOutput)
                    }
                }
            }
            group.addTask {
                do { try await Task.sleep(for: codeWait) } catch { return nil }
                return watcher.hasCode ? nil : .failure(.unrecognizedOutput)
            }
            var result: Result<Void, GHApprovalError> = .failure(.cancelled)
            for await next in group {
                guard let next else { continue }
                result = next
                group.cancelAll()
                break
            }
            return result
        }
        try outcome.get()
    }

    /// The usable github.com accounts with their login state and scope status (A3).
    public func accounts() async throws(GHError) -> [GHAccountStatusModel] {
        try await listing().accounts
    }

    /// Every github.com account of A3: the usable ones and those FX Vault cannot use, with why.
    public func listing() async throws(GHError) -> GHAccountListingModel {
        let output = try await service.execute(try Self.statusCommand(), token: nil)
        return try Self.decodeListing(output)
    }

    /// Decodes A3 (usable accounts only) and wipes stdout.
    public static func decodeAccounts(_ output: GHCommandOutput) throws(GHError) -> [GHAccountStatusModel] {
        try decodeListing(output).accounts
    }

    /// Decodes A3 and wipes stdout.
    public static func decodeListing(_ output: GHCommandOutput) throws(GHError) -> GHAccountListingModel {
        defer { output.wipe() }
        let dto = try GHJSONDecoding.decode(AuthStatusDTO.self, from: output.stdout)
        return GHAccountListingModel(dto: dto)
    }

    /// A copy of `login`'s token: from the cache, else from A4 (then cached).
    ///
    /// - Throws: ``GHError/cancelled`` when the cache was purged (the vault locked) while A4 ran:
    ///   the fresh token is wiped instead of being cached or used.
    public func token(for login: String) async throws(GHError) -> SecretBytes {
        if let cached = tokenCache.token(for: login) {
            return cached
        }
        let generation = tokenCache.generation
        let fresh = try await fetchToken(for: login)
        guard tokenCache.store(fresh.copy(), for: login, ifGeneration: generation) else {
            fresh.wipe()
            throw .cancelled
        }
        return fresh
    }

    /// After `.tokenRevoked`: drops the cached token, runs A4 once, caches the result, and
    /// returns true when the token changed (the caller then retries once, §7.3).
    ///
    /// - Throws: ``GHError/cancelled`` when the cache was purged while A4 ran.
    public func refreshToken(for login: String, replacing stale: SecretBytes) async throws(GHError) -> Bool {
        tokenCache.invalidate(login: login)
        let generation = tokenCache.generation
        let fresh = try await fetchToken(for: login)
        let changed = !stale.withUnsafeBytes { fresh.constantTimeEquals($0) }
        guard tokenCache.store(fresh, for: login, ifGeneration: generation) else { throw .cancelled }
        return changed
    }

    /// Re-check: forget `login`'s token so the next call runs A4.
    public func invalidate(login: String) {
        tokenCache.invalidate(login: login)
    }

    private func fetchToken(for login: String) async throws(GHError) -> SecretBytes {
        let output = try await service.execute(try Self.tokenCommand(login: login), token: nil)
        return try Self.decodeToken(output)
    }

    /// Trims A4's output (the token plus a newline) into a new buffer and wipes stdout.
    /// Throws ``GHError/notAuthenticated`` when nothing is left.
    public static func decodeToken(_ output: GHCommandOutput) throws(GHError) -> SecretBytes {
        defer { output.wipe() }
        let token = output.stdout.withUnsafeBytes { bytes -> SecretBytes in
            var start = bytes.startIndex
            var end = bytes.endIndex
            while start < end, isWhitespace(bytes[start]) { start += 1 }
            while end > start, isWhitespace(bytes[end - 1]) { end -= 1 }
            return SecretBytes(copying: UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
        }
        guard !token.isEmpty else { throw .notAuthenticated }
        return token
    }

    private static let whitespaceBytes: Set<UInt8> = [
        UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"),
    ]

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        whitespaceBytes.contains(byte)
    }
}
