import Foundation

extension AppViewModel {
    /// The view model of the Nearby Chat window. The window is its own scene, not a main-window
    /// sheet, so it gets ``FeatureDependencies`` with its own actions: no router, locks still
    /// reach it (``addLockObserver(_:)``), and "present" brings the main window forward.
    func makeNearbyChatViewModel() -> NearbyChatViewModel {
        NearbyChatViewModel(app: self, dependencies: nearbyChatDependencies())
    }

    func nearbyChatDependencies() -> FeatureDependencies {
        FeatureDependencies(container: container, actions: MainActions(
            present: { [weak self] _ in self?.requestMainWindow() },
            refresh: { _ in },
            beginSyncActivity: { [weak self] in self?.beginSyncActivity() ?? SyncActivity.untracked() },
            addLockObserver: { [weak self] observer in self?.addLockObserver(observer) },
            isGitHubReady: { [weak self] in self?.ghStatus.isReady ?? false },
            select: { _ in }
        ))
    }
}
