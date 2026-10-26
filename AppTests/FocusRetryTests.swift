import Testing
@testable import FXVault

/// ``FocusRetry``: the ⌘K palette's field and the sidebar search ask for the focus again until
/// it lands, and stop when the request is gone.
@MainActor
@Suite("Focus retry")
struct FocusRetryTests {
    /// A field still being inserted takes the focus on the third ask.
    @Test func asksAgainUntilTheFocusLands() async {
        var asks = 0
        let didFocus = await FocusRetry.take(isFocused: { asks >= 3 }) {
            asks += 1
        }
        #expect(didFocus)
        #expect(asks == 3)
    }

    /// The request is gone (the sidebar search took the focus or dropped it): no other ask.
    @Test func stopsWhenTheRequestIsGone() async {
        var asks = 0
        let didFocus = await FocusRetry.take(isFocused: { false }, isWanted: { asks < 2 }) {
            asks += 1
        }
        #expect(!didFocus)
        #expect(asks == 2)
    }

    /// A newer request cancels the loop (the sidebar's `task(id:)`): it stops asking at once.
    @Test func stopsWhenCancelled() async {
        let asks = Counter()
        let task = Task {
            await FocusRetry.take(isFocused: { false }) {
                asks.value += 1
            }
        }
        task.cancel()
        #expect(!(await task.value))
        #expect(asks.value <= 1)
    }

    /// A field that never takes the focus (the window is not key) is given up after the timeout.
    @Test func givesUpAfterTheTimeout() async {
        var asks = 0
        let didFocus = await FocusRetry.take(isFocused: { false }) {
            asks += 1
        }
        #expect(!didFocus)
        #expect(asks == Int(Theme.Durations.focusTimeout / Theme.Durations.focusRetry))
    }
}
