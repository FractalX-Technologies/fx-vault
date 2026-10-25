import Foundation
import VaultCore

/// Every gh operation FX Vault performs, keyed to the command catalog (tasks/todo.md §8).
public enum GHOperation: String, Sendable, Hashable, CaseIterable {
    case version = "A1"
    case authStatus = "A3"
    case authToken = "A4"
    case orgList = "A5"
    case orgMembership = "A6"
    case repoList = "B1"
    case repoView = "B2"
    case environmentList = "B3"
    case environmentGet = "B4"
    case branchPolicyList = "B5"
    case secretList = "B6"
    case variableList = "B8"
    case orgSecretList = "B12"
    case orgVariableList = "B13"
    case orgSecretRepositories = "B14"
    case orgVariableRepositories = "B15"
    case gitignoreList = "B10g"
    case licenseList = "B10l"
    case repoCreate = "C1"
    case environmentUpsert = "C2"
    case branchPolicyAdd = "C3"
    case branchPolicyDelete = "C4"
    case secretSet = "C5"
    case secretDelete = "C6"
    case variableSet = "C7"
    case variableDelete = "C8"
    case environmentDelete = "C9"
    case orgSecretSet = "C10"
    case orgSecretDelete = "C11"
    case orgVariableSet = "C12"
    case orgVariableDelete = "C13"

    /// True for catalog section C (writes to GitHub).
    public var isWrite: Bool {
        switch self {
        case .repoCreate, .environmentUpsert, .branchPolicyAdd, .branchPolicyDelete,
             .secretSet, .secretDelete, .variableSet, .variableDelete, .environmentDelete,
             .orgSecretSet, .orgSecretDelete, .orgVariableSet, .orgVariableDelete:
            true
        default:
            false
        }
    }

    /// True when running the operation twice has the same effect as once (D12). Only repo
    /// creation is not idempotent; a branch-policy POST of an existing pattern is a no-op
    /// redirect (§8 C3).
    public var isIdempotent: Bool {
        self != .repoCreate
    }

    /// True when the call runs with the account's `GH_TOKEN` (everything but A1, A3, A4).
    public var requiresToken: Bool {
        switch self {
        case .version, .authStatus, .authToken: false
        default: true
        }
    }

    /// True for `gh api` operations (the organization role, environments, branch policies and
    /// the repositories of a `selected` organization item, D4).
    public var usesAPI: Bool {
        switch self {
        case .orgMembership, .orgSecretRepositories, .orgVariableRepositories, .environmentList, .environmentGet, .branchPolicyList, .environmentUpsert,
             .branchPolicyAdd, .branchPolicyDelete, .environmentDelete:
            true
        default:
            false
        }
    }

    /// True for `gh api -i` calls whose stdout starts with an HTTP status line.
    public var includesResponseHead: Bool {
        switch self {
        case .environmentGet, .environmentUpsert, .branchPolicyAdd, .branchPolicyDelete,
             .environmentDelete:
            true
        default:
            false
        }
    }

    /// `gh api -i` statuses that make gh exit non-zero but count as success: a bare 303 for
    /// C3 (an existing pattern whose redirect had no `Location`, §8 C3).
    public var acceptedNonZeroExitStatuses: Set<Int> {
        self == .branchPolicyAdd ? [Self.seeOtherStatus] : []
    }

    private static let seeOtherStatus = 303

    /// The process timeout (§5.10).
    public var timeout: Duration {
        switch self {
        case .authToken: Timeouts.ghAuthToken
        case .repoList: Timeouts.ghRepoList
        default: Timeouts.ghDefault
        }
    }
}

/// One gh invocation built by the argv builders (`GHReposCommands`, `GHSecretsCommands`, ...).
///
/// Only GitHubKit can create commands, so the public API cannot run arbitrary gh arguments
/// (and never an arbitrary `gh api` path). Every command has passed ``GHArgumentPolicy``.
///
/// `stdinValue` is the command's own copy of the value (secret value, variable value or JSON
/// body). ``GHCommandScheduler`` copies it into a fresh ``StdinPayload`` per attempt and wipes
/// it when the command finishes; callers that run a command through ``GHCommandService``
/// directly call ``wipe()`` themselves.
public struct GHCommand: Sendable {
    public let operation: GHOperation
    /// argv after the gh executable.
    public let arguments: [String]
    /// The template logged instead of the argv (§4.5), for example
    /// `secret set {n} --repo={o}/{r} --env={e}`.
    public let logTemplate: String
    /// Throttle cost (D12): 0 for reads, 1 per write, 2 for a variable update.
    public let writeCost: Int
    let stdinValue: SecretBytes?

    init(
        operation: GHOperation,
        arguments: [String],
        logTemplate: String,
        stdinValue: SecretBytes? = nil,
        writeCost: Int? = nil
    ) throws(GHError) {
        try GHArgumentPolicy.validate(arguments)
        self.operation = operation
        self.arguments = arguments
        self.logTemplate = logTemplate
        self.stdinValue = stdinValue
        self.writeCost = writeCost ?? (operation.isWrite ? Limits.defaultWriteCost : 0)
    }

    /// True when the command carries a stdin value.
    public var hasStdin: Bool {
        stdinValue != nil
    }

    /// A fresh payload for one attempt (the runner wipes it).
    func makeStdinPayload() -> StdinPayload {
        guard let stdinValue else { return .empty }
        return StdinPayload(transferring: stdinValue.copy())
    }

    /// Wipes the command's stdin value. Idempotent.
    public func wipe() {
        stdinValue?.wipe()
    }
}

extension GHCommand: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "GHCommand(\(operation.rawValue): \(logTemplate))"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["operation": operation, "logTemplate": logTemplate], displayStyle: .struct)
    }
}

/// Flags gh must never receive (§5.10): values travel only on stdin, nothing is cached,
/// nothing verbose, nothing cloned.
public enum GHArgumentPolicy {
    /// Forbidden flags, matched exactly and as `--flag=value`.
    public static let forbiddenFlags: Set<String> = [
        "--body", "-b", "-f", "--env-file", "--no-store", "--verbose", "--show-token", "--cache",
        "--clone", "-F", "--raw-field", "--field",
    ]

    /// Throws ``GHError/forbiddenArgument(_:)`` for the first forbidden flag in `arguments`.
    public static func validate(_ arguments: [String]) throws(GHError) {
        for argument in arguments where isForbidden(argument) {
            throw .forbiddenArgument(flagName(of: argument))
        }
    }

    /// True when `argument` is a forbidden flag (`--body`, `--body=x`, `-bx`, ...).
    public static func isForbidden(_ argument: String) -> Bool {
        if forbiddenFlags.contains(flagName(of: argument)) { return true }
        // Short flags with an attached value: `-bVALUE`, `-fFILE`, `-FKEY=V`.
        let shortFlags = forbiddenFlags.filter { $0.count == shortFlagLength }
        return !argument.hasPrefix("--") && shortFlags.contains { argument.hasPrefix($0) }
    }

    private static let shortFlagLength = 2

    private static func flagName(of argument: String) -> String {
        guard argument.hasPrefix("-"), let equals = argument.firstIndex(of: "=") else { return argument }
        return String(argument[argument.startIndex..<equals])
    }
}
