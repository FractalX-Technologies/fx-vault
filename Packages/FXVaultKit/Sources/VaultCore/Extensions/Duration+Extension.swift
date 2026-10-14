extension Duration {
    /// The duration in seconds as a `Double`, for `Date` arithmetic (`date + d.timeInterval`).
    public var timeInterval: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / Self.attosecondsPerSecond
    }

    private static let attosecondsPerSecond: Double = 1e18
}
