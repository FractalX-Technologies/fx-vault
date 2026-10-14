/// Whether a config item is a GitHub Actions secret or variable.
///
/// Raw values match `config_items.kind` (§6). Immutable once the row is synced (D11).
public enum ConfigKind: String, Sendable, Hashable, Codable, CaseIterable {
    case secret
    case variable
}

/// Where a config item lives on GitHub, without the environment identity.
public enum ConfigScopeLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case repository
    case environment
}

/// Where a config item lives: the repository itself or one of its environments.
///
/// Maps to `config_items.environment_id` (NULL means repository level). Immutable once the row
/// is synced (D11).
public enum ConfigScope: Sendable, Hashable {
    case repository
    case environment(EnvironmentID)

    /// Builds the scope from a nullable environment id (database form).
    public init(environmentID: EnvironmentID?) {
        if let environmentID {
            self = .environment(environmentID)
        } else {
            self = .repository
        }
    }

    /// The environment id, or nil at repository level (database form).
    public var environmentID: EnvironmentID? {
        switch self {
        case .repository: nil
        case .environment(let id): id
        }
    }

    /// The scope without the environment identity, for limits and capability checks.
    public var level: ConfigScopeLevel {
        switch self {
        case .repository: .repository
        case .environment: .environment
        }
    }
}
