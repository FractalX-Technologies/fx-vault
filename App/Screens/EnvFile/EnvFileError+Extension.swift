import Darwin
import EnvTools
import VaultData

/// Localized text for `.env` import and export failures (UI feature contract: feature-owned error
/// types conform to ``PresentableError``). Messages never include values or file contents.
nonisolated extension EnvFileError: PresentableError {
    var errorPresentation: ErrorPresentationModel {
        switch self {
        case .config(let error):
            error.presentation
        case .fileUnreadable, .parse:
            ErrorPresentationModel(
                title: String(localized: "error.envFile.read.title", defaultValue: "The .env file could not be read"),
                message: localizedMessage
            )
        case .write, .serialize:
            ErrorPresentationModel(
                title: String(localized: "error.envFile.write.title", defaultValue: "The .env file was not written"),
                message: localizedMessage
            )
        case .authorizationInvalid:
            ErrorPresentationModel(
                title: String(localized: "error.envFile.authorization.title", defaultValue: "Confirm it's you again"),
                message: localizedMessage
            )
        case .gitignoreNotRegularFile, .gitignoreUnreadable:
            ErrorPresentationModel(
                title: String(localized: "error.envFile.gitignore.title", defaultValue: ".gitignore was not changed"),
                message: localizedMessage
            )
        }
    }

    var localizedMessage: String {
        switch self {
        case .fileUnreadable:
            String(
                localized: "error.envFile.fileUnreadable",
                defaultValue: "FX Vault cannot open this file. Check that it exists and that you can read it."
            )
        case .parse(.fileTooLarge(let limit)):
            String(
                localized: "error.envFile.fileTooLarge",
                defaultValue: "The file is larger than \(Int64(limit).formatted(.byteCount(style: .file))). A .env file is usually a few kilobytes."
            )
        case .serialize:
            String(
                localized: "error.envFile.serialize",
                defaultValue: "A name in this scope cannot be written to a .env file. Nothing was written."
            )
        case .write(let error):
            error.envFileMessage
        case .authorizationInvalid:
            String(
                localized: "error.envFile.authorizationInvalid",
                defaultValue: "Each export needs a fresh Touch ID or master password check. Confirm it's you and try again."
            )
        case .gitignoreNotRegularFile:
            String(
                localized: "error.envFile.gitignoreNotRegularFile",
                defaultValue: "The repository's .gitignore is not a regular file (for example a link). Add the line yourself."
            )
        case .gitignoreUnreadable:
            String(
                localized: "error.envFile.gitignoreUnreadable",
                defaultValue: "The repository's .gitignore could not be read as text. Add the line yourself."
            )
        case .config(let error):
            error.localizedMessage
        }
    }
}

nonisolated extension SecureFileWriteError {
    /// Why a `.env` or `.gitignore` write failed.
    var envFileMessage: String {
        switch self {
        case .notAFileURL, .invalidFileName:
            String(localized: "error.fileWrite.invalidName", defaultValue: "Choose a file name in a folder on this Mac.")
        case .parentDirectoryUnavailable:
            String(localized: "error.fileWrite.folderUnavailable", defaultValue: "The folder is no longer available. Choose another location.")
        case .destinationIsSymbolicLink:
            String(
                localized: "error.fileWrite.symbolicLink",
                defaultValue: "A link with this name exists. FX Vault never writes through a link: choose another name."
            )
        case .destinationIsNotRegularFile:
            String(
                localized: "error.fileWrite.notRegularFile",
                defaultValue: "Something other than a file already uses this name. Choose another name."
            )
        case .destinationExists:
            String(
                localized: "error.fileWrite.exists",
                defaultValue: "A file with this name appeared while exporting. Choose the location again to replace it."
            )
        case .systemCall(_, let code) where code == EACCES || code == EPERM || code == EROFS:
            String(
                localized: "error.fileWrite.permission",
                defaultValue: "FX Vault cannot write to this folder. Choose a folder you can write to, or allow FX Vault in System Settings › Privacy & Security › Files and Folders."
            )
        case .systemCall(_, let code) where code == ENOSPC || code == EDQUOT:
            String(localized: "error.fileWrite.diskFull", defaultValue: "The disk is full. Free some space and try again.")
        case .systemCall:
            String(localized: "error.fileWrite.generic", defaultValue: "The file could not be written. Try another location.")
        }
    }
}
