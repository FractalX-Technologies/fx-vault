import Foundation
import Observation

/// The one-time notice after migration `v16_drop_runtime_providers` (1.0) deleted the vault's
/// Supabase and Vercel destinations: their labels until OK, then never again.
@Observable
final class RetiredDestinationsNotice {
    private(set) var labels: [String] = []

    @ObservationIgnored private let read: () throws -> [String]
    @ObservationIgnored private let clear: () throws -> Void

    init(load: @escaping () throws -> [String], dismiss: @escaping () throws -> Void) {
        read = load
        clear = dismiss
    }

    /// Reads the labels; called when the main window appears unlocked.
    func load() {
        do {
            labels = try read()
        } catch {
            AppLog.ui.error("Reading the retired destinations failed")
        }
    }

    /// OK on the notice. The alert's binding and its button both call it, so the second call
    /// does nothing.
    func dismiss() {
        guard !labels.isEmpty else { return }
        labels = []
        do {
            try clear()
        } catch {
            AppLog.ui.error("Clearing the retired destinations notice failed")
        }
    }
}
