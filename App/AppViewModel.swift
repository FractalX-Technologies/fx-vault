import Observation

/// The top-level state of the vault, which decides the root screen.
enum VaultPhase: Equatable {
    /// No vault exists yet: show onboarding.
    case onboarding
    /// A vault exists and its keys are not in memory.
    case locked
    /// The vault keys are in memory.
    case unlocked
}

/// App-wide state shared by every scene.
///
/// Placeholder: the phase will come from `VaultRepository` and the gh status probe
/// starts at launch (tasks/todo.md §3, M1/M2).
@Observable
final class AppViewModel {
    private(set) var phase: VaultPhase

    @ObservationIgnored private let container: AppContainer

    init(container: AppContainer, phase: VaultPhase = .onboarding) {
        self.container = container
        self.phase = phase
    }
}
