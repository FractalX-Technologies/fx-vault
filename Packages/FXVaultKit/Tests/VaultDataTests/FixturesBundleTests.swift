import Foundation
import Testing
import VaultData

@Suite("VaultData test bundle")
struct FixturesBundleTests {
    @Test func fixturesAreBundled() {
        #expect(Bundle.module.url(forResource: "Fixtures", withExtension: nil) != nil)
    }
}
