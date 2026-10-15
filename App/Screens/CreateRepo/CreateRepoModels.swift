import Foundation
import GitHubKit
import VaultCore
import VaultData

/// Constants of the New Repository sheet (no magic numbers; sizes are in `Theme.Layout`).
nonisolated enum CreateRepoConstants {
    /// How long the name must stay unchanged before the availability check (§8 B2) runs.
    static let availabilityDebounce: Duration = .milliseconds(500)
    /// The masked stand-in shown for a staged value (never the value or its length).
    static let maskedValue = "••••••••"
}

/// Where a staged secret or variable goes: the repository itself or one staged environment.
nonisolated enum CreateRepoItemTargetModel: Hashable {
    case repository
    case environment(UUID)

    var level: ConfigScopeLevel {
        switch self {
        case .repository: .repository
        case .environment: .environment
        }
    }
}

/// One secret or variable typed into the New Repository sheet, held until Create stages it.
///
/// The value is the only copy outside the vault: it is never part of the text representation
/// (`description`, `debugDescription`, `dump`), and it is dropped after staging, on Cancel and on
/// lock.
nonisolated struct CreateRepoItemDraftModel: Identifiable, Equatable {
    let id: UUID
    var kind: ConfigKind
    /// The uppercase GitHub name (validated by ``GitHubNameValidator``).
    var name: String
    var value: String

    init(id: UUID = UUID(), kind: ConfigKind, name: String, value: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.value = value
    }

    /// The fold key used for duplicate checks within one scope and kind.
    var nameKey: String {
        GitHubNameValidator.foldKey(name)
    }
}

nonisolated extension CreateRepoItemDraftModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "CreateRepoItemDraftModel(kind: \(kind.rawValue), name: \(name), value: <redacted>)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: ["kind": kind, "name": name], displayStyle: .struct)
    }
}

/// One environment typed into the New Repository sheet, with its deployment branch policy and
/// its secrets and variables.
nonisolated struct CreateRepoEnvironmentDraftModel: Identifiable, Equatable {
    let id: UUID
    /// The NFC name (validated by ``EnvironmentNameValidator``).
    var name: String
    var policy: BranchPolicyDraftModel
    var items: [CreateRepoItemDraftModel]

    init(id: UUID = UUID(), name: String, policy: BranchPolicyDraftModel = .all, items: [CreateRepoItemDraftModel] = []) {
        self.id = id
        self.name = name
        self.policy = policy
        self.items = items
    }

    var nameKey: String {
        EnvironmentNameValidator.foldKey(name)
    }
}

nonisolated extension CreateRepoEnvironmentDraftModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "CreateRepoEnvironmentDraftModel(name: \(name), items: \(items.map(\.description)))"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: ["name": name, "policy": policy, "items": items], displayStyle: .struct)
    }
}

/// The live name check under the Name field (§10: "Probably available"; a taken name is only
/// confirmed by the create error during Sync).
nonisolated enum CreateRepoAvailabilityModel: Equatable {
    /// Nothing to check (no name, no owner).
    case idle
    /// Waiting for the debounce or for gh.
    case checking
    case probablyAvailable
    /// `gh repo view` found the repository: the name is taken.
    case taken
    /// The name breaks a GitHub rule (checked locally, no gh call).
    case invalid(NameRule)
    /// The check itself failed (offline, token); Create stays possible.
    case unknown(ErrorPresentationModel)

    /// True when Create must stay disabled.
    var blocksCreate: Bool {
        switch self {
        case .taken, .invalid: true
        case .idle, .checking, .probablyAvailable, .unknown: false
        }
    }
}

/// What the confirmation page shows after Create staged the repository. Names and counts only.
nonisolated struct CreateRepoStagedModel: Equatable {
    let repositoryID: RepoID
    let fullName: String
    let environmentCount: Int
    let secretCount: Int
    let variableCount: Int
    /// The clone destination (`<folder>/<name>`) when "Clone to my Mac" was on.
    let cloneFolder: URL?
    /// Items whose value lost trailing line breaks (`environment/NAME` or `NAME`).
    let strippedTrailingNewlines: [String]
}

/// The nested editor on screen (one at a time).
enum CreateRepoEditorRoute: Identifiable {
    case item(CreateRepoItemEditorViewModel)
    case environment(CreateRepoEnvironmentEditorViewModel)

    var id: ObjectIdentifier {
        switch self {
        case .item(let editor): ObjectIdentifier(editor)
        case .environment(let editor): ObjectIdentifier(editor)
        }
    }
}

/// Localized text shared by the New Repository views and view models.
nonisolated enum CreateRepoText {
    /// The eyebrow of the New Repository sheet and its nested editors.
    static var eyebrow: String {
        String(localized: "createRepo.eyebrow", defaultValue: "New repository")
    }

    static func policySummary(_ policy: BranchPolicyDraftModel) -> String {
        switch policy {
        case .all:
            String(localized: "branchPolicy.all", defaultValue: "All branches")
        case .protectedBranches:
            String(localized: "branchPolicy.protected", defaultValue: "Protected branches only")
        case .custom(let patterns):
            String(localized: "branchPolicy.custom", defaultValue: "Selected (\(patterns.count) rules)")
        }
    }

    static func kindTitle(_ kind: ConfigKind) -> String {
        switch kind {
        case .secret: String(localized: "createRepo.kind.secret", defaultValue: "Secret")
        case .variable: String(localized: "createRepo.kind.variable", defaultValue: "Variable")
        }
    }

    static func ownerTitle(_ owner: RepoOwnerChoiceModel) -> String {
        switch owner.ownerType {
        case .user:
            String(localized: "createRepo.owner.personal", defaultValue: "\(owner.login) (Personal)")
        case .organization:
            String(localized: "createRepo.owner.organization", defaultValue: "\(owner.login) (Organization)")
        }
    }

    /// "Environments: 2 · Secrets: 3 · Variables: 1" (counts only).
    static func contentSummary(environments: Int, secrets: Int, variables: Int) -> String {
        String(
            localized: "createRepo.summary.content",
            defaultValue: "Environments: \(environments) · Secrets: \(secrets) · Variables: \(variables)"
        )
    }
}
