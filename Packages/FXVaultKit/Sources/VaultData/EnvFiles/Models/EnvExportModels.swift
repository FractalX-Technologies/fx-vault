import EnvTools
import Foundation

/// What an export of one scope would write (§7.8, M5 `EnvExportScreen`), names only.
public struct EnvExportPreviewModel: Sendable, Hashable {
    /// Keys the file will contain, in file order.
    public let exportedNames: [String]
    /// Secrets left out because their value is missing locally (§7.8: "Export skips them and
    /// lists their names").
    public let valueMissingNames: [String]
    /// Variables left out because a secret of the same name is exported (a `.env` key can
    /// appear once).
    public let nameCollisions: [String]

    public init(exportedNames: [String], valueMissingNames: [String], nameCollisions: [String]) {
        self.exportedNames = exportedNames
        self.valueMissingNames = valueMissingNames
        self.nameCollisions = nameCollisions
    }
}

/// The warnings for an export destination (§5.13): iCloud sync and git exposure.
public struct EnvExportDestinationModel: Sendable, Hashable {
    public let cloudSyncStatus: CloudSyncStatus
    /// Where the file stands with git; nil when the check failed.
    public let gitExposure: GitExposureModel?

    public init(cloudSyncStatus: CloudSyncStatus, gitExposure: GitExposureModel?) {
        self.cloudSyncStatus = cloudSyncStatus
        self.gitExposure = gitExposure
    }

    /// git could not be asked; the screen says "could not check git" (never "safe").
    public var gitCheckFailed: Bool {
        gitExposure == nil
    }
}

/// What an export wrote.
public struct EnvExportResultModel: Sendable, Hashable {
    public let fileURL: URL
    public let preview: EnvExportPreviewModel

    public init(fileURL: URL, preview: EnvExportPreviewModel) {
        self.fileURL = fileURL
        self.preview = preview
    }
}
