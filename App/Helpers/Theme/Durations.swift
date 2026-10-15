import SwiftUI

extension Theme {
    /// Animation timings, in seconds.
    enum Durations {
        static let fast: TimeInterval = 0.15
        static let standard: TimeInterval = 0.25
        static let slow: TimeInterval = 0.4

        static let standardAnimation = Animation.easeInOut(duration: standard)

        /// Pause after the last keystroke in the .env paste editor before the preview re-parses.
        static let envPasteParseDebounce: Duration = .milliseconds(300)

        /// How long a change of the network path must hold before the connectivity banner and
        /// the offline gating follow it (a flapping path never reaches the UI).
        static let connectivityDebounce: Duration = .seconds(2)
    }
}
