import Darwin
import Foundation
import VaultCore

/// Where a gh candidate came from (§5.10, v0.3.1).
public enum GHCandidateSource: String, Sendable, Hashable, Codable {
    /// Preferences › Advanced › gh path override (the only candidate when set).
    case override
    /// `command -v gh` in the probed shell: the gh Terminal runs.
    case shell
    /// `/opt/homebrew/bin`, `/usr/local/bin`.
    case homebrew
    /// A directory of the shell PATH.
    case shellPATH
    /// MacPorts, Nix and `~/.local/bin`.
    case fallback
}

/// The one other user who owns a gh file or one of its folders (§5.10 consented trust).
public struct GHBinaryOwnerModel: Sendable, Hashable, Codable {
    public let uid: UInt32
    /// The account name from the user database; nil when it has none.
    public let name: String?

    public init(uid: UInt32, name: String?) {
        self.uid = uid
        self.name = name
    }
}

/// A gh the user chose to trust although another (non-root) user owns it (Preferences ›
/// Advanced lists it with Revoke). ``GHLocator`` accepts exactly ``path`` while every owner
/// that is not the user or root is ``ownerUID`` and nothing is writable by others.
public struct GHTrustedBinaryModel: Sendable, Hashable, Codable {
    /// The candidate path as found (for example `/opt/homebrew/bin/gh`), not the resolved one,
    /// so the consent survives `brew upgrade gh`.
    public let path: String
    public let ownerUID: UInt32

    public init(path: String, ownerUID: UInt32) {
        self.path = path
        self.ownerUID = ownerUID
    }
}

/// One gh candidate as ``GHLocator`` saw it.
public struct GHCandidateReportModel: Sendable, Hashable {
    public let path: String
    public let source: GHCandidateSource
    /// The path with symlinks resolved; nil when nothing is there.
    public let resolvedPath: String?
    /// Why the candidate is not used; nil when it passed the trust check.
    public let rejection: GHBinaryRejection?
    /// The one other user who owns the file or a folder. With an ``GHBinaryRejection/untrustedOwner``
    /// rejection it means that ownership is the only problem, so the user may trust it.
    public let foreignOwner: GHBinaryOwnerModel?
    /// Accepted only because the user trusted ``foreignOwner`` for this path.
    public let isTrustedByConsent: Bool
    /// `gh --version`, when it ran (the decisive candidate, or every trusted one for diagnostics).
    public var version: GHVersion?
    /// Why `gh --version` failed, when it did.
    public var versionFailure: GHError?

    public init(
        path: String,
        source: GHCandidateSource,
        resolvedPath: String?,
        rejection: GHBinaryRejection?,
        foreignOwner: GHBinaryOwnerModel? = nil,
        isTrustedByConsent: Bool = false,
        version: GHVersion? = nil,
        versionFailure: GHError? = nil
    ) {
        self.path = path
        self.source = source
        self.resolvedPath = resolvedPath
        self.rejection = rejection
        self.foreignOwner = foreignOwner
        self.isTrustedByConsent = isTrustedByConsent
        self.version = version
        self.versionFailure = versionFailure
    }

    /// Something exists at ``path``.
    public var isFound: Bool {
        rejection != .notFound
    }

    /// Passed the trust check (possibly by consent).
    public var isAccepted: Bool {
        rejection == nil
    }

    /// Rejected only because one other user owns it: the user may trust it.
    public var canBeTrusted: Bool {
        rejection == .untrustedOwner && foreignOwner != nil
    }

    /// Installed by Homebrew (a Homebrew bin folder, or a file inside a Cellar).
    public var isHomebrew: Bool {
        let directory = (path as NSString).deletingLastPathComponent
        return GHLocator.homebrewDirectories.contains(directory)
            || (resolvedPath?.contains(GHLocator.homebrewCellarComponent) ?? false)
    }

    /// The consent that would let ``GHLocator`` accept this candidate, when it can be trusted.
    public var trustConsent: GHTrustedBinaryModel? {
        guard canBeTrusted, let foreignOwner else { return nil }
        return GHTrustedBinaryModel(path: path, ownerUID: foreignOwner.uid)
    }
}

/// What ``GHLocator/inspect(overridePath:shell:trustedBinary:checksEveryVersion:)`` found
/// (v0.3.1): every candidate in search order, the one that decided, and the outcome.
public struct GHLocatorReportModel: Sendable, Hashable {
    public let candidates: [GHCandidateReportModel]
    /// The candidate that decided the outcome: the gh in use, or the one that blocked
    /// detection. Nil when no candidate exists.
    public let decisiveIndex: Int?
    public let outcome: Result<GHInstallationModel, GHError>

    public init(candidates: [GHCandidateReportModel], decisiveIndex: Int?, outcome: Result<GHInstallationModel, GHError>) {
        self.candidates = candidates
        self.decisiveIndex = decisiveIndex
        self.outcome = outcome
    }

    /// The candidate that decided the outcome.
    public var decisive: GHCandidateReportModel? {
        decisiveIndex.map { candidates[$0] }
    }

    /// The gh in use, when detection succeeded.
    public var installation: GHInstallationModel? {
        try? outcome.get()
    }
}
