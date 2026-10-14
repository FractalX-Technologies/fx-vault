import Foundation
import Testing

@Suite("EnvTools fixtures")
struct FixturesBundleTests {
    @Test func fixturesAreBundled() throws {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        #expect(FileManager.default.fileExists(atPath: fixtures.appending(path: "sample.env").path(percentEncoded: false)))
    }
}
