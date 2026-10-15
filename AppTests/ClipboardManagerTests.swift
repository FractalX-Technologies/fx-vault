import AppKit
import Testing
import VaultCore
@testable import FXVault

@MainActor
@Suite("ClipboardManager")
struct ClipboardManagerTests {
    /// A uniquely named pasteboard per test; released at the end.
    private func withPasteboard(_ body: (NSPasteboard, ManualClock, ClipboardManager) async throws -> Void) async rethrows {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.fractalx.fxvault.tests.clipboard.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let clock = ManualClock()
        let manager = ClipboardManager(pasteboard: pasteboard, clock: clock)
        try await body(pasteboard, clock, manager)
    }

    @Test func copyWritesValueAndPrivacyMarkers() async {
        await withPasteboard { pasteboard, _, manager in
            manager.copy("FXV_FIXTURE_VALUE")
            #expect(pasteboard.string(forType: .string) == "FXV_FIXTURE_VALUE")
            let types = pasteboard.types ?? []
            #expect(types.contains(ClipboardManager.Marker.concealed))
            #expect(types.contains(ClipboardManager.Marker.transient))
            #expect(pasteboard.string(forType: ClipboardManager.Marker.source) == ClipboardManager.Marker.sourceIdentifier)
            #expect(manager.ownsContents)
        }
    }

    /// v0.4.0 ⌘C on the table: item names, transient (never concealed: they are not values),
    /// never cleared, and recognized by FX Vault's paste only until anything else is copied.
    @Test func itemNamesAreTransientAndRecognizedUntilSomethingElseIsCopied() async {
        await withPasteboard { pasteboard, _, manager in
            manager.copyItemNames(["API_KEY", "DB_URL"])
            #expect(pasteboard.string(forType: .string) == "API_KEY\nDB_URL")
            let types = pasteboard.types ?? []
            #expect(types.contains(ClipboardManager.Marker.transient))
            #expect(!types.contains(ClipboardManager.Marker.concealed))
            #expect(pasteboard.string(forType: ClipboardManager.Marker.source) == ClipboardManager.Marker.sourceIdentifier)
            #expect(manager.holdsItemNames)
            #expect(manager.pendingClear == nil)
            #expect(!manager.ownsContents, "lock does not clear names")

            pasteboard.clearContents()
            pasteboard.setString("REGION=eu", forType: .string)
            #expect(!manager.holdsItemNames)

            manager.copyItemNames(["API_KEY"])
            manager.copy("FXV_FIXTURE_VALUE")
            #expect(!manager.holdsItemNames, "a value copy replaces the names")
        }
    }

    @Test func clearsAfterDelayWhenUnchanged() async {
        await withPasteboard { pasteboard, clock, manager in
            manager.copy("FXV_FIXTURE_VALUE")
            await clock.waitForSleepers(count: 1)
            clock.advance(by: manager.clearDelay - .seconds(1))
            #expect(pasteboard.string(forType: .string) == "FXV_FIXTURE_VALUE")
            clock.advance(by: .seconds(1))
            await manager.pendingClear?.value
            #expect(pasteboard.string(forType: .string) == nil)
            #expect(!manager.ownsContents)
        }
    }

    @Test func leavesForeignWritesAlone() async {
        await withPasteboard { pasteboard, clock, manager in
            manager.copy("FXV_FIXTURE_VALUE")
            let pending = manager.pendingClear
            await clock.waitForSleepers(count: 1)
            pasteboard.clearContents()
            pasteboard.setString("someone else", forType: .string)
            #expect(!manager.ownsContents)
            clock.advance(by: manager.clearDelay)
            await pending?.value
            #expect(pasteboard.string(forType: .string) == "someone else")
        }
    }

    @Test func clearIfOwnedOnLock() async {
        await withPasteboard { pasteboard, _, manager in
            manager.copy("FXV_FIXTURE_VALUE")
            manager.clearIfOwned()
            #expect(pasteboard.string(forType: .string) == nil)
            #expect(manager.pendingClear == nil)
        }
    }

    @Test func clearIfOwnedSkipsForeignWrites() async {
        await withPasteboard { pasteboard, _, manager in
            manager.copy("FXV_FIXTURE_VALUE")
            pasteboard.clearContents()
            pasteboard.setString("someone else", forType: .string)
            manager.clearIfOwned()
            #expect(pasteboard.string(forType: .string) == "someone else")
        }
    }

    @Test func secondCopyRestartsTheTimer() async {
        await withPasteboard { pasteboard, clock, manager in
            manager.copy("first")
            await clock.waitForSleepers(count: 1)
            clock.advance(by: .seconds(20))
            manager.copy("second")
            await clock.waitForSleepers(count: 1)
            clock.advance(by: .seconds(20))
            #expect(pasteboard.string(forType: .string) == "second")
            clock.advance(by: .seconds(10))
            await manager.pendingClear?.value
            #expect(pasteboard.string(forType: .string) == nil)
        }
    }

    @Test func lockClearsOwnedClipboard() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.app.didUnlock()
        harness.container.clipboard.copy("FXV_FIXTURE_VALUE")
        harness.app.lock(trigger: .manual)
        #expect(harness.pasteboardString == nil)
    }
}
