import Foundation
import Testing
import SyncEngine

@Suite("SyncEngine test bundle")
struct FixturesBundleTests {
    @Test func fixturesAreBundled() {
        #expect(Bundle.module.url(forResource: "Fixtures", withExtension: nil) != nil)
    }
}
