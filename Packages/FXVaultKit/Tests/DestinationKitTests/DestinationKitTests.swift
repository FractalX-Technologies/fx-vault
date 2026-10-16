import CryptoKit
import Foundation
import Testing
@testable import DestinationKit

@Suite("DestinationKit")
struct DestinationKitSmokeTests {
    @Test func moduleLoads() {
        #expect(String(describing: DestinationKit.self) == "DestinationKit")
    }

    @Test func fixturesAreBundled() throws {
        #expect(try Fixture.data("keyvault/list-page1.json").count > 0)
    }

    /// Fixtures are public: no real organization, account, team or project identifiers
    /// (tasks/todo.md §12.4). Same SHA-256 denylist and tokenization as GitHubKit's
    /// `fixturesContainNoDenylistedNames`, so the names never appear in this repository.
    @Test func fixturesContainNoDenylistedNames() throws {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let denylist: Set<String> = [
            "ebb0e3e2cc2dc56d551d1c322fc4f3529dac4af26a3ac4a0297f7cb26fdc85fa",
            "27a65e66023ac5352761e5a0db80610c1580ab00f412208b22207f641140d374",
            "177ff24b4b08dbfb272041d7775e0f9aa7c348febdd2218020c6da095366479d",
            "f263381b69af1d6ae42178afb730c406f53075505873c5437293234376d39e21",
            "042a431f39823bc59bc43aa001c29e0d5a91989b39cb7d006ea91e02a43b294a",
        ]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        #expect(files.filter { !$0.hasDirectoryPath }.count > 1)
        for file in files where !file.hasDirectoryPath {
            let text = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self).lowercased()
            let tokens = Set(text.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            for token in tokens {
                let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
                #expect(!denylist.contains(digest), "\(file.lastPathComponent) contains a denylisted name")
            }
        }
    }
}
