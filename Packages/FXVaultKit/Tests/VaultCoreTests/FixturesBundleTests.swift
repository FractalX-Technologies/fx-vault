import Foundation
import Testing
import VaultCore

@Suite("VaultCore test bundle")
struct FixturesBundleTests {
    @Test func fixturesAreBundled() {
        #expect(Bundle.module.url(forResource: "Fixtures", withExtension: nil) != nil)
    }
}
