import Foundation
import Testing
import VaultData

@Suite("VaultData skeleton")
struct VaultDataModuleTests {
    @Test func moduleLinks() {
        #expect(VaultDataModule.name == "VaultData")
    }

    @Test func fixturesAreBundled() {
        #expect(Bundle.module.url(forResource: "Fixtures", withExtension: nil) != nil)
    }
}
