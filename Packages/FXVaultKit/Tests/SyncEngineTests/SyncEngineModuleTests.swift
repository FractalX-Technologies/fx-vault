import Foundation
import Testing
import SyncEngine

@Suite("SyncEngine skeleton")
struct SyncEngineModuleTests {
    @Test func moduleLinks() {
        #expect(SyncEngineModule.name == "SyncEngine")
    }

    @Test func fixturesAreBundled() {
        #expect(Bundle.module.url(forResource: "Fixtures", withExtension: nil) != nil)
    }
}
