import GitHubKit

/// The sheet decides on the case, never on gh's text (rule 6); every failure but a timeout
/// shows the same message with the command to run instead.
extension GHApprovalError: PresentableError {
    nonisolated var errorPresentation: ErrorPresentationModel {
        switch self {
        case .timedOut:
            ErrorPresentationModel(
                title: String(localized: "ghApproval.error.expired.title", defaultValue: "The code expired"),
                message: String(
                    localized: "ghApproval.error.expired",
                    defaultValue: "GitHub's code is valid for 15 minutes. Try Again for a new one, or run this in Terminal:"
                )
            )
        case .cancelled, .failed, .unrecognizedOutput, .notActiveAccount:
            ErrorPresentationModel(
                title: String(localized: "ghApproval.error.title", defaultValue: "GitHub CLI didn't finish the approval"),
                message: String(
                    localized: "ghApproval.error",
                    defaultValue: "Run this in Terminal, approve in the browser, then Check Again:"
                )
            )
        }
    }
}
