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
    }
}
