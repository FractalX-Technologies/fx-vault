/// What the viewer may change in a repository (§2 Permissions, §7.3 preflight).
///
/// Derived from gh `viewerPermission` (stored as `has_admin` / `has_push`), `isArchived` and
/// `isUnavailable`. Environments always need admin. Whether a WRITE collaborator may manage
/// repository-level secrets and variables is decided by the M3 write spike (Q6): see
/// ``WriteCollaboratorPolicy``.
public enum RepoCapabilityModel: Sendable, Hashable {
    /// Admin: environments, policies, secrets and variables at every scope.
    case full
    /// WRITE collaborator, if the spike confirms it: repository-level items only.
    case repoLevelOnly
    /// Nothing can be changed.
    case readOnly(ReadOnlyReason)

    /// Why a repository is read-only. The app maps each case to its chip text.
    public enum ReadOnlyReason: String, Sendable, Hashable, CaseIterable {
        /// The repository is archived on GitHub.
        case archived
        /// The viewer lacks the permission the change needs (admin, or push under
        /// ``WriteCollaboratorPolicy/repoLevelOnly``).
        case adminRequired
        /// The repository could not be read (SAML, removed, no longer listed).
        case unavailable
    }

    /// Derives the capability. Archived wins over unavailable, which wins over permissions.
    public init(
        hasAdmin: Bool,
        hasPush: Bool,
        isArchived: Bool,
        isUnavailable: Bool = false,
        writePolicy: WriteCollaboratorPolicy = .default
    ) {
        if isArchived {
            self = .readOnly(.archived)
        } else if isUnavailable {
            self = .readOnly(.unavailable)
        } else if hasAdmin {
            self = .full
        } else if hasPush, writePolicy == .repoLevelOnly {
            self = .repoLevelOnly
        } else {
            self = .readOnly(.adminRequired)
        }
    }

    /// Derives the capability from gh's `viewerPermission` (nil means no known permission).
    public init(
        viewerPermission: ViewerPermission?,
        isArchived: Bool,
        isUnavailable: Bool = false,
        writePolicy: WriteCollaboratorPolicy = .default
    ) {
        self.init(
            hasAdmin: viewerPermission?.hasAdmin ?? false,
            hasPush: viewerPermission?.hasPush ?? false,
            isArchived: isArchived,
            isUnavailable: isUnavailable,
            writePolicy: writePolicy
        )
    }

    /// Environments, their branch policies and environment-level items.
    public var canEditEnvironments: Bool {
        self == .full
    }

    /// Repository-level secrets and variables.
    public var canEditRepoLevelItems: Bool {
        switch self {
        case .full, .repoLevelOnly: true
        case .readOnly: false
        }
    }

    /// Whether items at the given scope can be changed.
    public func canEditItems(at level: ConfigScopeLevel) -> Bool {
        switch level {
        case .repository: canEditRepoLevelItems
        case .environment: canEditEnvironments
        }
    }

    /// The read-only reason for items at the given scope, or nil when they can be changed.
    public func readOnlyReason(for level: ConfigScopeLevel) -> ReadOnlyReason? {
        if case .readOnly(let reason) = self { return reason }
        return canEditItems(at: level) ? nil : .adminRequired
    }
}

/// How WRITE (and MAINTAIN) collaborators map onto ``RepoCapabilityModel``.
///
/// GitHub documents admin for repository secrets and variables, but this is unverified for gh
/// (§2). Until the M3 spike (Q6) confirms otherwise, WRITE is read-only (``default``).
public enum WriteCollaboratorPolicy: String, Sendable, Hashable, CaseIterable {
    /// WRITE can manage repository-level secrets and variables.
    case repoLevelOnly
    /// WRITE cannot change anything.
    case readOnly

    /// The policy in force until the M3 spike result is recorded.
    public static let `default`: WriteCollaboratorPolicy = .readOnly
}
