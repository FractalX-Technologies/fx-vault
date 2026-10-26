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

        /// Between two tries to focus a field that is still appearing (``FocusRetry``: the ⌘K
        /// palette's field, the sidebar search after Edit › Find on a hidden sidebar), and how
        /// long it keeps trying: longer than the sidebar's slide.
        static let focusRetry: Duration = .milliseconds(100)
        static let focusTimeout: Duration = .seconds(1)

        /// How long the notch island says "Unlocked" before it goes away.
        static let islandUnlocked: Duration = .milliseconds(900)

        /// How long the notes editor's "3 values set from the clipboard" stays (board Place-Paste).
        static let notesToast: Duration = .seconds(4)
    }
}
