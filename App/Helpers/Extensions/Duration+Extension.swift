import VaultCore

nonisolated extension Duration {
    /// Whole seconds, for user-facing text ("clears in 30 seconds").
    var wholeSeconds: Int {
        Int(components.seconds)
    }

    /// Whole days, for user-facing text ("every 14 days").
    var wholeDays: Int {
        Int(components.seconds / Timeouts.secondsPerDay)
    }
}
