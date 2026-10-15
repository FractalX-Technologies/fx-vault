import SwiftUI

extension Theme {
    /// Motion and timings (docs/DESIGN.md, "Motion"). FractalX motion is short and quiet: one
    /// 140 ms ease-out for state changes and one critically damped spring for things that move.
    enum Durations {
        /// 140 ms: hover, press, focus, selection, chips and banners appearing.
        static let interaction: TimeInterval = 0.14
        /// The default animation for state changes.
        static let interactionAnimation = Animation.easeOut(duration: interaction)
        /// Moving content: the selected segment, expanding rows, banners sliding in.
        static let springResponse: TimeInterval = 0.28
        static let spring = Animation.spring(duration: springResponse, bounce: 0)

        /// Legacy name of ``interactionAnimation`` (v0.2 screens).
        static let standardAnimation = interactionAnimation

        /// Pause after the last keystroke in the .env paste editor before the preview re-parses.
        static let envPasteParseDebounce: Duration = .milliseconds(300)

        /// How long a change of the network path must hold before the connectivity banner and
        /// the offline gating follow it (a flapping path never reaches the UI).
        static let connectivityDebounce: Duration = .seconds(2)
    }
}
