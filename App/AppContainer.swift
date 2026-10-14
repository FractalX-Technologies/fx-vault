import Foundation

/// Composition root: builds the repositories and managers that view models depend on.
///
/// Placeholder: repositories arrive with their milestones. Only the mode exists today.
/// - `live`: the real vault, keychain and gh.
/// - `preview`: in-memory and side-effect free; used by SwiftUI previews and by the
///   app when it hosts the test bundle (nothing under Application Support, no shell probe).
/// - `test`: for unit tests that inject their own fakes.
struct AppContainer: Equatable {
    enum Mode: Equatable {
        case live
        case preview
        case test
    }

    /// Set by XCTest in the host app's environment while it runs the test bundle.
    private static let xcTestConfigurationKey = "XCTestConfigurationFilePath"

    static let live = AppContainer(mode: .live)
    static let preview = AppContainer(mode: .preview)
    static let test = AppContainer(mode: .test)

    let mode: Mode

    /// Whether this container may touch the disk, the keychain or spawn processes.
    var hasSideEffects: Bool {
        mode == .live
    }

    /// The container for this process: `preview` while hosting tests, otherwise `live`.
    static func forCurrentProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppContainer {
        environment[xcTestConfigurationKey] == nil ? .live : .preview
    }
}
