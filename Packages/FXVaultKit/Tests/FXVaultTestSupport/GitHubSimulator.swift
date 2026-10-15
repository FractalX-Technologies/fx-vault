import Foundation
import GitHubKit
import os
import VaultCore

/// argv matchers for the gh commands the sync engine runs (tasks/todo.md §8).
public enum GHMatch {
    public typealias Matcher = FakeCommandRunner.Matcher

    public static func prefix(_ prefix: [String]) -> Matcher {
        { Array($0.prefix(prefix.count)) == prefix }
    }

    public static func secretSet(_ name: String? = nil) -> Matcher {
        item(["secret", "set"], name)
    }

    public static func variableSet(_ name: String? = nil) -> Matcher {
        item(["variable", "set"], name)
    }

    public static func secretDelete(_ name: String? = nil) -> Matcher {
        item(["secret", "delete"], name)
    }

    public static func variableDelete(_ name: String? = nil) -> Matcher {
        item(["variable", "delete"], name)
    }

    public static let secretList = prefix(["secret", "list"])
    public static let variableList = prefix(["variable", "list"])
    public static let repoCreate = prefix(["repo", "create"])
    public static let repoView = prefix(["repo", "view"])
    public static let authToken = prefix(["auth", "token"])

    /// A `gh api` call with `method` whose path (query removed) ends with `suffix`.
    public static func api(_ method: String, _ suffix: String) -> Matcher {
        { arguments in
            guard arguments.first == "api",
                  let index = arguments.firstIndex(of: "-X"),
                  arguments.indices.contains(index + 1),
                  arguments[index + 1] == method,
                  let path = arguments.first(where: { $0.hasPrefix("repos/") })
            else { return false }
            let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
            return bare.hasSuffix(suffix)
        }
    }

    /// Any command whose argv contains `--env=<name>`.
    public static func environment(_ name: String) -> Matcher {
        { $0.contains("--env=\(name)") }
    }

    public static func all(_ matchers: Matcher...) -> Matcher {
        { arguments in matchers.allSatisfy { $0(arguments) } }
    }

    private static func item(_ prefix: [String], _ name: String?) -> Matcher {
        { arguments in
            Array(arguments.prefix(prefix.count)) == prefix
                && (name == nil || arguments.dropFirst(prefix.count).first == name)
        }
    }

    /// True for a command that writes to GitHub.
    public static func isWrite(_ arguments: [String]) -> Bool {
        if arguments.starts(with: ["secret", "set"]) || arguments.starts(with: ["variable", "set"]) { return true }
        if arguments.starts(with: ["secret", "delete"]) || arguments.starts(with: ["variable", "delete"]) { return true }
        if arguments.starts(with: ["repo", "create"]) { return true }
        if arguments.first == "api", let index = arguments.firstIndex(of: "-X"), arguments.indices.contains(index + 1) {
            return arguments[index + 1] != "GET"
        }
        return false
    }
}

/// A stateful stand-in for GitHub behind gh, for SyncEngine and VaultData tests (tasks/todo.md
/// §12.2). Lives in the `FXVaultTestSupport` target, which no product links.
///
/// Every call goes through a ``FakeCommandRunner`` first, which records it (argv, environment,
/// stdin) and answers any scripted one-shot response (exit codes, stdout, stderr). Calls nothing
/// scripted matches are answered by the simulation, which keeps secrets (with `updatedAt`),
/// variables, environments and branch policies like GitHub does, in gh's output formats.
public final class GitHubSimulator: CommandRunning, Sendable {
    public struct Item: Sendable {
        public var name: String
        public var value: String
        public var updatedAt: Date
    }

    public struct Pattern: Sendable {
        public var id: Int64
        public var name: String
        public var type: BranchPatternType
    }

    public struct Environment: Sendable {
        public var id: Int64
        public var name: String
        public var policy: BranchPolicyKind
        public var patterns: [Pattern] = []
        /// Raw JSON objects of rules other than `branch_policy`, e.g. a reviewers rule.
        public var foreignRules: [String] = []
        public var updatedAt: Date
    }

    public struct Options: Sendable {
        /// `gh secret set` of an existing secret leaves `updatedAt` unchanged (Q6 unknown).
        public var secretSetKeepsUpdatedAt = false
        /// Variables are stored with this value instead of the one sent.
        public var variableStoredValue: String?
        /// Environments created under these fold keys get these ids.
        public var environmentIDs: [String: Int64] = [:]
    }

    private struct Hook: Sendable {
        let matcher: FakeCommandRunner.Matcher
        let action: @Sendable () -> Void
    }

    private struct State: Sendable {
        var owner: String
        var name: String
        var repositoryID = "R_simulated"
        var visibility: RepoVisibility
        var exists: Bool
        var environments: [String: Environment] = [:]
        var secrets: [String: [String: Item]] = [:]
        var variables: [String: [String: Item]] = [:]
        var tick: TimeInterval = 0
        var nextID: Int64 = 1000
        var options = Options()
        var applyFirst: [FakeCommandRunner.Matcher] = []
        var hooks: [Hook] = []
    }

    public static let epoch = Date(timeIntervalSince1970: 1_767_225_600)
    public static let refreshedToken = "fake-token-refreshed"
    public let scripted = FakeCommandRunner()
    private let state: OSAllocatedUnfairLock<State>

    public init(owner: String = "owner-a", name: String = "api", exists: Bool = true, visibility: RepoVisibility = .private) {
        state = OSAllocatedUnfairLock(initialState: State(owner: owner, name: name, visibility: visibility, exists: exists))
    }

    // MARK: - Scripting

    /// Queues a one-shot scripted response (wins over the simulation).
    public func enqueue(_ response: FakeCommandRunner.Response, matching matcher: @escaping FakeCommandRunner.Matcher) {
        scripted.enqueue(response, matching: matcher)
    }

    /// Queues a one-shot response that is returned **after** the simulation applied the call
    /// (a write that reached GitHub although gh reported a failure, e.g. a timeout).
    public func enqueueAfterApplying(_ response: FakeCommandRunner.Response, matching matcher: @escaping FakeCommandRunner.Matcher) {
        state.withLock { $0.applyFirst.append(matcher) }
        scripted.enqueue(response, matching: matcher)
    }

    /// Runs `action` after the next call matching `matcher` (once).
    public func afterCall(matching matcher: @escaping FakeCommandRunner.Matcher, perform action: @escaping @Sendable () -> Void) {
        state.withLock { $0.hooks.append(Hook(matcher: matcher, action: action)) }
    }

    public func configure(_ body: (inout Options) -> Void) {
        state.withLockUnchecked { body(&$0.options) }
    }

    public var invocations: [FakeCommandRunner.Invocation] {
        scripted.invocations
    }

    /// argv of every call, in order.
    public var calls: [[String]] {
        invocations.map(\.arguments)
    }

    /// argv of every write, in order.
    public var writes: [[String]] {
        calls.filter(GHMatch.isWrite)
    }

    // MARK: - State

    public func setRepository(exists: Bool, name: String? = nil, visibility: RepoVisibility? = nil) {
        state.withLock { state in
            state.exists = exists
            if let name { state.name = name }
            if let visibility { state.visibility = visibility }
        }
    }

    public var repositoryExists: Bool {
        state.withLock { $0.exists }
    }

    @discardableResult
    public func addSecret(_ name: String, environment: String? = nil, updatedAt: Date? = nil) -> Date {
        state.withLock { state in
            let date = updatedAt ?? Self.nextTimestamp(&state)
            state.secrets[Self.scopeKey(environment), default: [:]][Self.itemKey(name)] = Item(name: name, value: "", updatedAt: date)
            return date
        }
    }

    @discardableResult
    public func addVariable(_ name: String, value: String, environment: String? = nil) -> Date {
        state.withLock { state in
            let date = Self.nextTimestamp(&state)
            state.variables[Self.scopeKey(environment), default: [:]][Self.itemKey(name)] = Item(name: name, value: value, updatedAt: date)
            return date
        }
    }

    public func removeSecret(_ name: String, environment: String? = nil) {
        state.withLock { _ = $0.secrets[Self.scopeKey(environment)]?.removeValue(forKey: Self.itemKey(name)) }
    }

    public func secret(_ name: String, environment: String? = nil) -> Item? {
        state.withLock { $0.secrets[Self.scopeKey(environment)]?[Self.itemKey(name)] }
    }

    public func variable(_ name: String, environment: String? = nil) -> Item? {
        state.withLock { $0.variables[Self.scopeKey(environment)]?[Self.itemKey(name)] }
    }

    public func secretNames(environment: String? = nil) -> [String] {
        state.withLock { ($0.secrets[Self.scopeKey(environment)] ?? [:]).values.map(\.name).sorted() }
    }

    public func variableNames(environment: String? = nil) -> [String] {
        state.withLock { ($0.variables[Self.scopeKey(environment)] ?? [:]).values.map(\.name).sorted() }
    }

    @discardableResult
    public func addEnvironment(
        _ name: String,
        id: Int64? = nil,
        policy: BranchPolicyKind = .all,
        patterns: [(String, BranchPatternType)] = [],
        foreignRules: [String] = []
    ) -> Int64 {
        state.withLock { state in
            let environmentID = id ?? Self.nextID(&state)
            var environment = Environment(
                id: environmentID,
                name: name,
                policy: policy,
                foreignRules: foreignRules,
                updatedAt: Self.nextTimestamp(&state)
            )
            for (pattern, type) in patterns {
                environment.patterns.append(Pattern(id: Self.nextID(&state), name: pattern, type: type))
            }
            state.environments[EnvironmentNameValidator.foldKey(name)] = environment
            return environmentID
        }
    }

    public func environment(_ name: String) -> Environment? {
        state.withLock { $0.environments[EnvironmentNameValidator.foldKey(name)] }
    }

    public func removeEnvironment(_ name: String) {
        state.withLock { state in
            let key = EnvironmentNameValidator.foldKey(name)
            state.environments[key] = nil
            state.secrets[key] = nil
            state.variables[key] = nil
        }
    }

    public var environmentNames: [String] {
        state.withLock { $0.environments.values.map(\.name).sorted() }
    }

    // MARK: - CommandRunning

    public func run(_ spec: CommandSpec) async throws(CommandRunnerError) -> CommandResult {
        let result = try await scripted.run(spec)
        let stdin = scripted.invocations.last?.stdin ?? Data()
        let arguments = spec.arguments
        let isUnmatched = result.exitCode == FakeCommandRunner.unmatchedExitCode && result.stderr == FakeCommandRunner.unmatchedStderr
        let final: CommandResult
        if isUnmatched {
            final = simulate(arguments, stdin: stdin)
        } else {
            let applies = state.withLock { state -> Bool in
                guard let index = state.applyFirst.firstIndex(where: { $0(arguments) }) else { return false }
                state.applyFirst.remove(at: index)
                return true
            }
            if applies { _ = simulate(arguments, stdin: stdin) }
            final = result
        }
        let hook = state.withLock { state -> Hook? in
            guard let index = state.hooks.firstIndex(where: { $0.matcher(arguments) }) else { return nil }
            return state.hooks.remove(at: index)
        }
        hook?.action()
        return final
    }

    // MARK: - Simulation

    private func simulate(_ arguments: [String], stdin: Data) -> CommandResult {
        state.withLock { state in
            switch (arguments.first, arguments.dropFirst().first) {
            case ("secret", "list"): Self.list(arguments, kind: .secret, state: state)
            case ("variable", "list"): Self.list(arguments, kind: .variable, state: state)
            case ("secret", "set"): Self.set(arguments, kind: .secret, value: stdin, state: &state)
            case ("variable", "set"): Self.set(arguments, kind: .variable, value: stdin, state: &state)
            case ("secret", "delete"): Self.delete(arguments, kind: .secret, state: &state)
            case ("variable", "delete"): Self.delete(arguments, kind: .variable, state: &state)
            case ("repo", "create"): Self.createRepository(arguments, state: &state)
            case ("repo", "view"): Self.viewRepository(arguments, state: state)
            case ("auth", "token"): Self.output(Self.refreshedToken + "\n")
            case ("api", _): Self.api(arguments, body: stdin, state: &state)
            default: Self.failure("unknown command")
            }
        }
    }

    private static func list(_ arguments: [String], kind: ConfigKind, state: State) -> CommandResult {
        let environment = environmentFlag(arguments)
        guard state.exists, environment.map({ state.environments[EnvironmentNameValidator.foldKey($0)] != nil }) ?? true else {
            return failure("failed to get \(kind.rawValue)s: HTTP 404: Not Found (https://api.github.com/repos/x)")
        }
        let items = ((kind == .secret ? state.secrets : state.variables)[scopeKey(environment)] ?? [:]).values
            .sorted { $0.name < $1.name }
        let rows: [[String: Any]] = items.map { item in
            var row: [String: Any] = ["name": item.name, "updatedAt": iso(item.updatedAt)]
            if kind == .variable {
                row["value"] = item.value
                row["createdAt"] = iso(item.updatedAt)
            }
            return row
        }
        return output(json(rows))
    }

    private static func set(_ arguments: [String], kind: ConfigKind, value: Data, state: inout State) -> CommandResult {
        let name = arguments[2]
        let environment = environmentFlag(arguments)
        guard state.exists, environment.map({ state.environments[EnvironmentNameValidator.foldKey($0)] != nil }) ?? true else {
            return failure("failed to set \(kind.rawValue) \"\(name)\": HTTP 404: Not Found (https://api.github.com/repos/x)")
        }
        let key = scopeKey(environment)
        var text = String(decoding: value, as: UTF8.self)
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        switch kind {
        case .secret:
            let existing = state.secrets[key]?[itemKey(name)]
            let date = state.options.secretSetKeepsUpdatedAt && existing != nil
                ? existing?.updatedAt ?? epoch
                : nextTimestamp(&state)
            state.secrets[key, default: [:]][itemKey(name)] = Item(name: name, value: text, updatedAt: date)
        case .variable:
            let stored = state.options.variableStoredValue ?? text
            state.variables[key, default: [:]][itemKey(name)] = Item(name: name, value: stored, updatedAt: nextTimestamp(&state))
        }
        return output("")
    }

    private static func delete(_ arguments: [String], kind: ConfigKind, state: inout State) -> CommandResult {
        let name = arguments[2]
        let key = scopeKey(environmentFlag(arguments))
        let removed: Item? = switch kind {
        case .secret: state.secrets[key]?.removeValue(forKey: itemKey(name))
        case .variable: state.variables[key]?.removeValue(forKey: itemKey(name))
        }
        guard removed != nil else {
            return failure("failed to delete \(kind.rawValue) \(name): HTTP 404: Not Found (https://api.github.com/repos/x)")
        }
        return output("")
    }

    private static func createRepository(_ arguments: [String], state: inout State) -> CommandResult {
        let parts = arguments[2].split(separator: "/").map(String.init)
        guard !state.exists else {
            return failure("GraphQL: Name already exists on this account (createRepository)")
        }
        state.exists = true
        state.owner = parts[0]
        state.name = parts[1]
        state.visibility = arguments.contains("--public") ? .public : (arguments.contains("--internal") ? .internal : .private)
        return output("https://github.com/\(state.owner)/\(state.name)\n")
    }

    private static func viewRepository(_ arguments: [String], state: State) -> CommandResult {
        let fullName = arguments[2]
        guard state.exists, fullName.lowercased() == "\(state.owner)/\(state.name)".lowercased() else {
            return failure("GraphQL: Could not resolve to a Repository with the name '\(fullName)'. (repository)")
        }
        let row: [String: Any] = [
            "id": state.repositoryID, "name": state.name, "nameWithOwner": "\(state.owner)/\(state.name)",
            "owner": ["login": state.owner], "isPrivate": state.visibility.isPrivate,
            "visibility": state.visibility.rawValue, "isArchived": false, "isFork": false,
            "viewerPermission": "ADMIN", "viewerCanAdminister": true, "defaultBranchRef": ["name": "main"],
            "sshUrl": "git@github.com:\(state.owner)/\(state.name).git", "createdAt": iso(epoch),
        ]
        return output(json(row))
    }

    // MARK: gh api

    private static func api(_ arguments: [String], body: Data, state: inout State) -> CommandResult {
        guard let index = arguments.firstIndex(of: "-X"), let path = arguments.first(where: { $0.hasPrefix("repos/") }) else {
            return failure("gh: HTTP 400")
        }
        let method = arguments[index + 1]
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let segments = bare.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard state.exists else { return apiFailure(404, "Not Found") }
        let environmentName = segments.count > 4 ? segments[4] : nil
        let environmentKey = environmentName.map(EnvironmentNameValidator.foldKey)
        switch (method, segments.count) {
        case ("GET", 4):
            let environments = state.environments.values.sorted { $0.name < $1.name }.map { environmentJSON($0) }
            return output(json([["total_count": environments.count, "environments": environments]]))
        case ("GET", 5):
            guard let key = environmentKey, let environment = state.environments[key] else { return apiFailure(404, "Not Found") }
            return apiResponse(200, "OK", body: json(environmentJSON(environment)))
        case ("PUT", 5):
            guard let name = environmentName, let key = environmentKey else { return apiFailure(422, "Validation Failed") }
            let policy = parsePolicy(body)
            var environment = state.environments[key] ?? Environment(
                id: state.options.environmentIDs[key] ?? nextID(&state),
                name: name,
                policy: policy,
                updatedAt: nextTimestamp(&state)
            )
            if environment.policy != policy, policy != .custom { environment.patterns = [] }
            environment.policy = policy
            environment.updatedAt = nextTimestamp(&state)
            state.environments[key] = environment
            return apiResponse(200, "OK", body: json(environmentJSON(environment)))
        case ("DELETE", 5):
            guard let key = environmentKey, state.environments.removeValue(forKey: key) != nil else {
                return apiFailure(404, "Not Found")
            }
            state.secrets[key] = nil
            state.variables[key] = nil
            return apiResponse(204, "No Content", body: nil)
        case ("GET", 6):
            guard let key = environmentKey, let environment = state.environments[key], environment.policy == .custom else {
                return apiFailure(404, "Not Found")
            }
            let policies = environment.patterns.map(patternJSON)
            return output(json([["total_count": policies.count, "branch_policies": policies]]))
        case ("POST", 6):
            guard let key = environmentKey, var environment = state.environments[key], environment.policy == .custom else {
                return apiFailure(404, "Not Found")
            }
            let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let name = request["name"] as? String ?? ""
            let type = BranchPatternType(rawValue: request["type"] as? String ?? "branch") ?? .branch
            if let existing = environment.patterns.first(where: { $0.name == name && $0.type == type }) {
                return apiResponse(200, "OK", body: json(patternJSON(existing)))
            }
            let pattern = Pattern(id: nextID(&state), name: name, type: type)
            environment.patterns.append(pattern)
            state.environments[key] = environment
            return apiResponse(200, "OK", body: json(patternJSON(pattern)))
        case ("DELETE", 7):
            guard let key = environmentKey, var environment = state.environments[key],
                  let id = Int64(segments[6]), environment.patterns.contains(where: { $0.id == id })
            else { return apiFailure(404, "Not Found") }
            environment.patterns.removeAll { $0.id == id }
            state.environments[key] = environment
            return apiResponse(204, "No Content", body: nil)
        default:
            return apiFailure(404, "Not Found")
        }
    }

    private static func parsePolicy(_ body: Data) -> BranchPolicyKind {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let flags = object["deployment_branch_policy"] as? [String: Any]
        else { return .all }
        if flags["custom_branch_policies"] as? Bool == true { return .custom }
        return flags["protected_branches"] as? Bool == true ? .protected : .all
    }

    private static func environmentJSON(_ environment: Environment) -> [String: Any] {
        var rules: [Any] = environment.foreignRules.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        let policy: Any
        switch environment.policy {
        case .all:
            policy = NSNull()
        case .protected:
            policy = ["protected_branches": true, "custom_branch_policies": false]
            rules.append(["id": 1, "node_id": "GA_branch", "type": "branch_policy"])
        case .custom:
            policy = ["protected_branches": false, "custom_branch_policies": true]
            rules.append(["id": 1, "node_id": "GA_branch", "type": "branch_policy"])
        }
        return [
            "id": environment.id, "node_id": "EN_\(environment.id)", "name": environment.name,
            "created_at": iso(epoch), "updated_at": iso(environment.updatedAt),
            "protection_rules": rules, "deployment_branch_policy": policy,
        ]
    }

    private static func patternJSON(_ pattern: Pattern) -> [String: Any] {
        ["id": pattern.id, "node_id": "BP_\(pattern.id)", "name": pattern.name, "type": pattern.type.rawValue]
    }

    // MARK: Output helpers

    public static func apiResponse(_ status: Int, _ reason: String, body: String?) -> CommandResult {
        output("HTTP/2.0 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\n\r\n" + (body ?? ""))
    }

    public static func apiFailure(_ status: Int, _ reason: String) -> CommandResult {
        CommandResult(
            exitCode: 1,
            stdout: SecretBytes(utf8: "HTTP/2.0 \(status) \(reason)\r\nContent-Type: application/json\r\n\r\n{\"message\":\"\(reason)\"}"),
            stderr: "gh: \(reason) (HTTP \(status))\n"
        )
    }

    private static func output(_ text: String) -> CommandResult {
        CommandResult(exitCode: 0, stdout: SecretBytes(utf8: text), stderr: "")
    }

    private static func failure(_ stderr: String) -> CommandResult {
        CommandResult(exitCode: 1, stdout: SecretBytes(count: 0), stderr: stderr + "\n")
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func environmentFlag(_ arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix("--env=") }.map { String($0.dropFirst("--env=".count)) }
    }

    private static func scopeKey(_ environment: String?) -> String {
        environment.map(EnvironmentNameValidator.foldKey) ?? ""
    }

    private static func itemKey(_ name: String) -> String {
        GitHubNameValidator.foldKey(name)
    }

    private static func nextTimestamp(_ state: inout State) -> Date {
        state.tick += 1
        return epoch.addingTimeInterval(state.tick)
    }

    private static func nextID(_ state: inout State) -> Int64 {
        state.nextID += 1
        return state.nextID
    }
}
