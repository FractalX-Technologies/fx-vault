import Foundation
import Network
import Testing
import VaultCore
@testable import SharingKit

/// §9.3 schema, manifest derivation and filtering.
@Suite("Share package model")
struct SharePackageModelTests {
    private func json(_ package: SharePackageModel) throws -> [String: Any] {
        let bytes = try SharePackageCoder.encode(package)
        let data = bytes.withUnsafeBytes { Data($0) }
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func encodesTheDocumentedSchema() throws {
        let package = PackageFactory.sample()
        let document = try json(package)
        #expect(document["schema"] as? String == "io.fractalx.fxvault.share")
        #expect(document["schemaVersion"] as? Int == 1)
        #expect(document["packageId"] as? String == package.packageID.uuidString)
        #expect(document["createdAt"] as? String == "2026-09-21T14:13:20Z")
        #expect(document["scope"] as? String == "repository")
        let producer = try #require(document["producer"] as? [String: Any])
        #expect(producer["app"] as? String == "FX Vault")
        let repository = try #require(document["repository"] as? [String: Any])
        #expect(repository["host"] as? String == "github.com")
        #expect(repository["githubRepoId"] as? String == PackageFactory.githubRepoID)
        let secrets = try #require(repository["secrets"] as? [[String: Any]])
        #expect(Set(secrets[0].keys) == ["id", "name", "value", "valueState", "githubUpdatedAt", "syncState"])
        #expect(secrets[1]["value"] is NSNull)
        #expect(secrets[1]["valueState"] as? String == "missing")
        let environments = try #require(repository["environments"] as? [[String: Any]])
        let policy = try #require(environments[0]["deploymentBranchPolicy"] as? [String: Any])
        #expect(policy["type"] as? String == "custom")
        let patterns = try #require(policy["patterns"] as? [[String: Any]])
        #expect(patterns.first?["name"] as? String == "main")
        #expect(patterns.first?["type"] as? String == "branch")
    }

    @Test func manifestNullsEveryValueAndKeepsValueState() throws {
        let package = PackageFactory.sample()
        let manifest = package.manifest()
        #expect(manifest.flattenedItems.allSatisfy { $0.item.value == nil })
        #expect(manifest.flattenedItems.map(\.item.valueState) == package.flattenedItems.map(\.item.valueState))
        #expect(manifest.allEntryIDs == package.allEntryIDs)

        let bytes = try SharePackageCoder.encode(manifest)
        let text = try #require(bytes.utf8String())
        for located in package.flattenedItems {
            if let value = located.item.value?.utf8String() {
                #expect(!text.contains(value))
            }
        }
        #expect(!text.contains("hash"))
        #expect(!text.contains("fingerprint"))
        // The original still has its values.
        #expect(package.repository.secrets[0].value != nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let package = PackageFactory.sample()
        let decoded = try SharePackageCoder.decode(try SharePackageCoder.encode(package))
        #expect(decoded == package)
    }

    @Test func acceptsFractionalSecondsOnInput() throws {
        let package = PackageFactory.sample()
        var text = try #require(try SharePackageCoder.encode(package).utf8String())
        text = text.replacingOccurrences(of: "2026-09-21T14:13:20Z", with: "2026-09-21T14:13:20.500Z")
        let decoded = try SharePackageCoder.decode(SecretBytes(utf8: text))
        #expect(decoded.createdAt == package.createdAt.addingTimeInterval(0.5))
    }

    @Test func decodingFailuresAreInvalidFile() {
        for text in ["", "[]", "{\"schema\":1}", "{}"] {
            #expect(throws: ShareError.invalidFile) { _ = try SharePackageCoder.decode(SecretBytes(utf8: text)) }
        }
    }

    @Test func binaryValuesCannotBeEncoded() {
        var package = PackageFactory.sample()
        package.repository.secrets[0].value = SecretBytes(copying: [0xC3, 0x28])
        #expect(throws: ShareError.invalidPackage(.valueNotUTF8)) { _ = try SharePackageCoder.encode(package) }
    }

    @Test func filteredKeepsSelectedItemsAndTheirEnvironments() throws {
        let package = PackageFactory.sample()
        let environment = try #require(package.repository.environments.first)
        let region = try #require(package.repository.variables.first)
        let dbPassword = try #require(environment.secrets.first)

        let onlyRegion = package.filtered(to: [region.id])
        #expect(onlyRegion.allEntryIDs == [region.id])

        let environmentItem = package.filtered(to: [dbPassword.id])
        #expect(environmentItem.allEntryIDs == [environment.id, dbPassword.id])
        #expect(environmentItem.repository.environments.first?.deploymentBranchPolicy == environment.deploymentBranchPolicy)

        let environmentOnly = package.filtered(to: [environment.id])
        #expect(environmentOnly.allEntryIDs == [environment.id])
        #expect(package.filtered(to: []).itemCount == 0)
    }

    @Test func wipeValuesZeroesEveryBuffer() {
        let package = PackageFactory.sample()
        let copy = package
        package.wipeValues()
        let values = copy.flattenedItems.compactMap { $0.item.value }
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { $0.isWiped })
    }

    @Test func policyFromVaultModelDropsTombstones() {
        let environmentID = EnvironmentID()
        let policy = DeploymentBranchPolicyModel.custom([
            BranchPatternModel(environmentID: environmentID, pattern: "main", type: .branch),
            BranchPatternModel(environmentID: environmentID, pattern: "old", type: .branch, isDeleted: true),
        ])
        let shared = ShareBranchPolicyModel(policy)
        #expect(shared.type == .custom)
        #expect(shared.patterns == [ShareBranchPatternModel(name: "main", type: .branch)])
        #expect(ShareBranchPolicyModel(.protectedBranches) == ShareBranchPolicyModel(type: .protected))
    }
}

@Suite("Nearby length framing")
struct NearbyLengthFramerTests {
    @Test func encodesWithABigEndianPrefix() throws {
        let framer = NearbyLengthFramer()
        #expect(try framer.encode(Data([0xAA, 0xBB])) == Data([0, 0, 0, 2, 0xAA, 0xBB]))
        #expect(throws: ShareError.transport(.malformedFrame)) { _ = try framer.encode(Data()) }
        #expect(throws: ShareError.transport(.oversizeFrame)) {
            _ = try framer.encode(Data(count: NearbyProtocol.maxTransportFrameBytes + 1))
        }
    }

    @Test func reassemblesFramesSplitAcrossReads() throws {
        var framer = NearbyLengthFramer()
        let first = try framer.encode(Data("hello".utf8))
        let second = try framer.encode(Data(repeating: 7, count: 1_000))
        let stream = first + second
        var frames: [Data] = []
        for byte in stream {
            frames += try framer.append(Data([byte]))
        }
        #expect(frames == [Data("hello".utf8), Data(repeating: 7, count: 1_000)])
        #expect(framer.pendingByteCount == 0)
    }

    @Test func returnsSeveralFramesFromOneRead() throws {
        var framer = NearbyLengthFramer()
        let stream = try framer.encode(Data([1])) + framer.encode(Data([2, 2])) + framer.encode(Data([3, 3, 3])).prefix(5)
        #expect(try framer.append(stream) == [Data([1]), Data([2, 2])])
        #expect(framer.pendingByteCount == 5)
    }

    @Test func rejectsHostilePrefixesBeforeBuffering() {
        var framer = NearbyLengthFramer(maxFrameBytes: 16)
        #expect(throws: ShareError.transport(.oversizeFrame)) { _ = try framer.append(Data([0, 0, 0, 17])) }
        var huge = NearbyLengthFramer()
        #expect(throws: ShareError.transport(.oversizeFrame)) { _ = try huge.append(Data([0xFF, 0xFF, 0xFF, 0xFF])) }
        var empty = NearbyLengthFramer()
        #expect(throws: ShareError.transport(.malformedFrame)) { _ = try empty.append(Data([0, 0, 0, 0])) }
    }

    @Test func accommodatesTheLargestProtocolFrame() throws {
        var framer = NearbyLengthFramer()
        let frame = Data(count: Limits.maxNearbyEncryptedFrameBytes)
        #expect(try framer.append(try framer.encode(frame)) == [frame])
    }

    @Test func networkConfigurationMatchesThePlan() {
        let parameters = NWNearbyConfiguration.parameters()
        #expect(parameters.acceptLocalOnly)
        #expect(parameters.prohibitedInterfaceTypes == [.cellular])
        #expect(!parameters.includePeerToPeer)
        let first = NWNearbyConfiguration.randomInstanceName()
        let second = NWNearbyConfiguration.randomInstanceName()
        #expect(first != second)
        #expect(first.hasPrefix(NWNearbyConfiguration.instanceNamePrefix))
        #expect(NearbyProtocol.bonjourServiceType == "_fxvault-share._tcp")
        let record = NWNearbyConfiguration.txtRecord()
        #expect(record.dictionary == ["v": "1"])
    }
}
