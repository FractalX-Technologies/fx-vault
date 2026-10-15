import Foundation
import VaultCore

/// A scope as GitHub identifies it: the repository itself, or one environment by its fold key.
///
/// GitHub environment names are case-insensitive, so two local rows whose names differ only in
/// case address the same remote scope (§7.1 normalization groups by this key).
public struct RemoteScopeKeyModel: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// ``EnvironmentNameValidator/foldKey(_:)`` of the environment name; nil for the repository.
    public let environmentKey: String?

    /// The repository level.
    public static let repository = RemoteScopeKeyModel(environmentKey: nil)

    /// The environment called `name` (any case).
    public static func environment(named name: String) -> RemoteScopeKeyModel {
        RemoteScopeKeyModel(environmentKey: EnvironmentNameValidator.foldKey(name))
    }

    private init(environmentKey: String?) {
        self.environmentKey = environmentKey
    }

    /// Repository first, then environments by fold key.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.environmentKey, rhs.environmentKey) {
        case (nil, nil): false
        case (nil, _): true
        case (_, nil): false
        case (let left?, let right?): left < right
        }
    }

    public var level: ConfigScopeLevel {
        environmentKey == nil ? .repository : .environment
    }

    /// `repo` or `env|<environment key>` (`sync_journal.target_key` of an environment change).
    public var journalKey: String {
        environmentKey.map { "\(SyncEngineConstants.journalEnvironmentTag)\(SyncEngineConstants.journalKeySeparator)\($0)" }
            ?? SyncEngineConstants.journalRepositoryTag
    }

    public var description: String {
        journalKey
    }
}

/// One secret or variable as GitHub identifies it: scope, kind and case-folded name.
///
/// This is the unit of §7.1 normalization ("keep one final operation for each remote key"), of
/// optimistic-concurrency checks (D27) and of drift suppression (§7.7). Its ``journalKey`` is the
/// `sync_journal.target_key` text, so drift can rebuild keys from journal rows.
public struct RemoteItemKeyModel: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let scope: RemoteScopeKeyModel
    public let kind: ConfigKind
    /// ``GitHubNameValidator/foldKey(_:)`` of the name.
    public let nameKey: String

    public init(scope: RemoteScopeKeyModel, kind: ConfigKind, name: String) {
        self.scope = scope
        self.kind = kind
        self.nameKey = GitHubNameValidator.foldKey(name)
    }

    /// Scope, then variables before secrets, then name.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.scope != rhs.scope { return lhs.scope < rhs.scope }
        if lhs.kind != rhs.kind { return lhs.kind == .variable }
        return lhs.nameKey < rhs.nameKey
    }

    /// `item|<kind>|<NAME>|repo` or `item|<kind>|<NAME>|env|<environment key>`.
    ///
    /// The environment key comes last because it is the only part that may contain the
    /// separator; item names never do (`^[A-Z_][A-Z0-9_]*$`).
    public var journalKey: String {
        let separator = String(SyncEngineConstants.journalKeySeparator)
        return [SyncEngineConstants.journalItemTag, kind.rawValue, nameKey, scope.journalKey]
            .joined(separator: separator)
    }

    /// Parses a ``journalKey``. Returns nil for any other text (for example an environment or
    /// repository key).
    public init?(journalKey: String) {
        let parts = journalKey.split(
            separator: SyncEngineConstants.journalKeySeparator,
            maxSplits: 3,
            omittingEmptySubsequences: false
        )
        let expectedParts = 4
        guard parts.count == expectedParts,
              parts[0] == SyncEngineConstants.journalItemTag,
              let kind = ConfigKind(rawValue: String(parts[1])),
              !parts[2].isEmpty,
              let scope = RemoteScopeKeyModel(scopeText: String(parts[3]))
        else { return nil }
        self.init(scope: scope, kind: kind, name: String(parts[2]))
    }

    public var description: String {
        journalKey
    }
}

extension RemoteScopeKeyModel {
    /// Parses ``journalKey`` (`repo` or `env|<key>`).
    init?(scopeText: String) {
        if scopeText == SyncEngineConstants.journalRepositoryTag {
            self = .repository
            return
        }
        let prefix = SyncEngineConstants.journalEnvironmentTag + String(SyncEngineConstants.journalKeySeparator)
        guard scopeText.hasPrefix(prefix) else { return nil }
        let key = String(scopeText.dropFirst(prefix.count))
        guard !key.isEmpty else { return nil }
        self.init(environmentKey: key)
    }

    /// Parses an environment journal key (`env|<key>`). Returns nil for anything else.
    public init?(environmentJournalKey: String) {
        guard let scope = RemoteScopeKeyModel(scopeText: environmentJournalKey),
              scope.environmentKey != nil
        else { return nil }
        self = scope
    }
}

/// What one change acts on; ``journalKey`` is written to `sync_journal.target_key`.
public enum ChangeTargetModel: Sendable, Hashable, Comparable {
    /// The repository itself (creation).
    case repository
    /// An environment (create, policy, patterns, rename target, delete).
    case environment(RemoteScopeKeyModel)
    /// A secret or variable.
    case item(RemoteItemKeyModel)

    public var journalKey: String {
        switch self {
        case .repository: SyncEngineConstants.journalRepositoryTag
        case .environment(let scope): scope.journalKey
        case .item(let key): key.journalKey
        }
    }

    /// The scope the target lives in (the repository for the repository itself).
    public var scope: RemoteScopeKeyModel {
        switch self {
        case .repository: .repository
        case .environment(let scope): scope
        case .item(let key): key.scope
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.journalKey < rhs.journalKey
    }
}
