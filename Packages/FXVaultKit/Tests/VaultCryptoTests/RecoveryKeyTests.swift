import Foundation
import Testing
import VaultCore
@testable import VaultCrypto

@Suite("RecoveryKey")
struct RecoveryKeyTests {
    /// A fixed sample key (the first recovery KAT vector).
    let sample: RecoveryKey
    let sampleText: String

    init() throws {
        let vector = try #require(try KATVectors.load().recovery.first)
        sample = RecoveryKey(material: SecretBytes(try hexData(vector.materialHex)))
        sampleText = vector.text
    }

    @Test func generatedKeysHaveTheDisplayShape() throws {
        let key = RecoveryKey.generate()
        let text = key.text
        #expect(text.count == Limits.recoveryKeyCharacters)
        #expect(text.allSatisfy { CrockfordBase32.alphabet.contains($0) })
        #expect(key.groups.count == Limits.recoveryKeyGroupCount)
        #expect(key.groups.allSatisfy { $0.count == Limits.recoveryKeyGroupSize })
        #expect(key.groups.joined() == text)
        #expect(key.formatted.count == text.count + Limits.recoveryKeyGroupCount - 1)

        let parsed = try RecoveryKey(parsing: key.formatted)
        #expect(parsed.text == text)
        #expect(RecoveryKey.generate().text != text)
    }

    @Test func detectsEverySingleCharacterSubstitution() {
        let characters = Array(sampleText)
        var checked = 0
        for index in characters.indices {
            for replacement in CrockfordBase32.alphabet where replacement != characters[index] {
                var mutated = characters
                mutated[index] = replacement
                #expect(throws: VaultError.invalidRecoveryKey, "position \(index) -> \(replacement)") {
                    try RecoveryKey(parsing: String(mutated))
                }
                checked += 1
            }
        }
        #expect(checked == Limits.recoveryKeyCharacters * (CrockfordBase32.alphabet.count - 1))
    }

    @Test func detectsEveryAdjacentTransposition() {
        let characters = Array(sampleText)
        var checked = 0
        for index in 0..<(characters.count - 1) where characters[index] != characters[index + 1] {
            var mutated = characters
            mutated.swapAt(index, index + 1)
            #expect(throws: VaultError.invalidRecoveryKey, "swap \(index)") {
                try RecoveryKey(parsing: String(mutated))
            }
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test func acceptsForgivingInput() throws {
        #expect(sampleText.contains("1") && sampleText.contains("0"))
        let typed = [
            sampleText.lowercased(),
            sample.formatted,
            sample.groups.joined(separator: " "),
            sample.groups.prefix(7).joined(separator: "-") + "\n" + sample.groups.suffix(7).joined(separator: "-"),
            "  " + sampleText + "\t",
            sampleText.replacingOccurrences(of: "1", with: "I").replacingOccurrences(of: "0", with: "O"),
            sampleText.replacingOccurrences(of: "1", with: "l").replacingOccurrences(of: "0", with: "o"),
            sampleText.replacingOccurrences(of: "1", with: "L").replacingOccurrences(of: "0", with: "o"),
        ]
        for input in typed {
            #expect(try RecoveryKey(parsing: input).text == sampleText, "\(input)")
        }
    }

    @Test func rejectsUAndOtherCharacters() {
        var characters = Array(sampleText)
        for bad in ["U", "u", "*", "é", "_", ".", "\u{200B}"] {
            characters[0] = Character(bad)
            #expect(throws: VaultError.invalidRecoveryKey, "\(bad)") {
                try RecoveryKey(parsing: String(characters))
            }
        }
    }

    @Test func rejectsWrongLengths() {
        for input in ["", String(sampleText.dropLast()), sampleText + "0", sampleText + sampleText] {
            #expect(throws: VaultError.invalidRecoveryKey) {
                try RecoveryKey(parsing: input)
            }
        }
    }

    @Test func confirmsGroups() {
        let groups = sample.groups
        #expect(sample.matches(group: groups[0], at: 0))
        #expect(sample.matches(group: groups[13].lowercased(), at: 13))
        #expect(!sample.matches(group: groups[0], at: 1) || groups[0] == groups[1])
        #expect(!sample.matches(group: groups[0], at: 14))
        #expect(!sample.matches(group: groups[0], at: -1))
        #expect(!sample.matches(group: "UUUU", at: 0))
        #expect(!sample.matches(group: String(groups[0].dropLast()), at: 0))
    }

    @Test func wipeZeroesTheMaterial() {
        let key = RecoveryKey.generate()
        key.wipe()
        #expect(key.withUnsafeBytes { $0.allSatisfy { $0 == 0 } })
    }
}

@Suite("CrockfordBase32")
struct CrockfordBase32Tests {
    @Test func roundTripsEveryLength() throws {
        for length in 0...40 {
            let bytes = SecureRandom.data(count: length)
            let text = CrockfordBase32.encode(bytes)
            #expect(text.count == CrockfordBase32.encodedLength(byteCount: length))
            let decoded = try #require(CrockfordBase32.decode(text))
            #expect(decoded.withUnsafeBytes { Data($0) } == bytes)
        }
    }

    @Test func rejectsNonCanonicalInput() {
        // One byte is 2 characters with 2 padding bits; "B9" has a non-zero padding bit.
        #expect(CrockfordBase32.decode("B8") != nil)
        #expect(CrockfordBase32.decode("B9") == nil)
        // No byte length encodes to 1, 3 or 6 characters.
        #expect(CrockfordBase32.decode("B") == nil)
        #expect(CrockfordBase32.decode("B8B") == nil)
        #expect(CrockfordBase32.decode("000000") == nil)
        #expect(CrockfordBase32.decode("B*") == nil)
        #expect(CrockfordBase32.decode("BU") == nil)
    }

    @Test func normalizesLikeCrockford() {
        #expect(CrockfordBase32.normalize("ab-cd ef\n") == "ABCDEF")
        #expect(CrockfordBase32.normalize("iIlLoO") == "111100")
        #expect(CrockfordBase32.normalize("u") == nil)
        #expect(CrockfordBase32.normalize("ä") == nil)
        #expect(CrockfordBase32.normalize("") == "")
    }

    @Test func encodesSecretBytes() {
        let secret = SecretBytes(copying: [UInt8(0x5A), 0x5B])
        #expect(CrockfordBase32.encode(secret) == "B9DG")
    }
}
