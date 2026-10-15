import Foundation
import Network
import Testing
import VaultCore
@testable import SharingKit

@Suite("Chat text sanitizer")
struct ChatTextSanitizerTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let label: String
        let input: String
        let expected: String
        var testDescription: String { label }
    }

    static let cases: [Case] = [
        Case(label: "plain", input: "Hello", expected: "Hello"),
        Case(label: "trimmed", input: "  Hello \n", expected: "Hello"),
        Case(label: "CRLF and CR", input: "a\r\nb\rc", expected: "a\nb\nc"),
        Case(label: "line and paragraph separators", input: "a\u{2028}b\u{2029}c", expected: "a\nb\nc"),
        Case(label: "tab kept", input: "a\tb", expected: "a\tb"),
        Case(label: "C0 and DEL removed", input: "a\u{0007}b\u{007F}c\u{0000}", expected: "abc"),
        Case(label: "C1 removed", input: "a\u{0085}b\u{009B}c", expected: "abc"),
        Case(label: "bidi override removed", input: "invoice\u{202E}fdp.exe", expected: "invoicefdp.exe"),
        Case(label: "bidi isolates and marks removed", input: "\u{2066}a\u{2069}\u{200F}b\u{061C}", expected: "ab"),
        Case(label: "zero width removed", input: "a\u{200B}b\u{2060}c\u{FEFF}", expected: "abc"),
        Case(label: "emoji joiner kept", input: "👩\u{200D}💻", expected: "👩\u{200D}💻"),
        Case(label: "NFC", input: "Cafe\u{0301}", expected: "Café"),
        Case(label: "only invisible", input: "\u{200B}\u{202E}\u{0007}", expected: ""),
        Case(label: "tag characters removed", input: "run\u{E0001}\u{E0072}\u{E006D}\u{E007F} ls", expected: "run ls"),
        Case(label: "invisible operators removed", input: "a\u{2061}b\u{2062}c\u{2063}d\u{2064}", expected: "abcd"),
        Case(label: "soft hyphen and Mongolian separator removed", input: "pass\u{00AD}word\u{180E}", expected: "password"),
        Case(label: "grapheme joiner removed", input: "a\u{034F}b", expected: "ab"),
        Case(label: "Hangul fillers removed", input: "\u{115F}\u{1160}a\u{3164}b\u{FFA0}", expected: "ab"),
        Case(label: "interlinear annotation removed", input: "a\u{FFF9}hidden\u{FFFA}b\u{FFFB}", expected: "ahiddenb"),
        Case(label: "emoji presentation kept", input: "❤\u{FE0F}", expected: "❤\u{FE0F}"),
        Case(label: "blank lines collapsed", input: "a\n\n\n\n\nb", expected: "a\n\nb"),
        Case(label: "whitespace-only lines collapsed", input: "a\n \n\t\n \nb\nc", expected: "a\n \nb\nc"),
        Case(
            label: "stacked marks capped",
            input: "q" + String(repeating: "\u{0301}\u{0300}", count: 20) + "o",
            expected: "q\u{0301}\u{0300}\u{0301}\u{0300}o"
        ),
        Case(label: "Vietnamese keeps its marks", input: "Tiê\u{0301}ng Viê\u{0323}t", expected: "Tiếng Việt"),
    ]

    @Test(arguments: cases)
    func sanitizes(_ testCase: Case) {
        // Compare scalars: String equality is canonical, and the marks matter here.
        #expect(Array(ChatTextSanitizer.sanitize(testCase.input).unicodeScalars) == Array(testCase.expected.unicodeScalars))
    }

    @Test func aWallOfNewlinesShrinksToOneBlankLine() {
        let wall = "top" + String(repeating: "\n", count: Limits.chatMessageBytes - 6) + "end"
        #expect(ChatTextSanitizer.sanitize(wall) == "top\n\nend")
    }
}

@Suite("Nearby transport configuration")
struct NearbyTransportConfigurationTests {
    @Test func peerToPeerWiFiIsEnabledWithoutCellular() {
        let parameters = NWNearbyConfiguration.parameters()
        #expect(parameters.includePeerToPeer)
        #expect(parameters.acceptLocalOnly)
        #expect(parameters.prohibitedInterfaceTypes == [.cellular])
    }

    @Test func eachPurposeHasItsOwnServiceType() {
        #expect(NearbyPurpose.share.bonjourServiceType == NearbyProtocol.bonjourServiceType)
        #expect(NearbyPurpose.chat.bonjourServiceType == NearbyChatProtocol.bonjourServiceType)
        #expect(Set(NearbyPurpose.allCases.map(\.bonjourServiceType)).count == NearbyPurpose.allCases.count)
        #expect(NearbyChatProtocol.bonjourServiceType == "_fxvault-chat._tcp")
        #expect(NWNearbyTransport.advertising().purpose == .share)
        #expect(NWNearbyTransport.advertising(purpose: .chat).purpose == .chat)
        #expect(NWNearbyBrowser(purpose: .chat).purpose == .chat)
        #expect(NWNearbyBrowser().purpose == .share)
    }

    @Test func chatAdvertisesUnderTheSanitizedDisplayName() {
        let transport = NWNearbyTransport.advertisingChat(displayName: "  Bob\u{202E}'s Mac  ")
        #expect(transport.serviceName == "Bob's Mac")
        #expect(transport.purpose == .chat)
        let long = String(repeating: "é", count: Limits.maxDisplayNameBytes)
        #expect((NWNearbyConfiguration.chatInstanceName(displayName: long).utf8.count) <= Limits.maxDisplayNameBytes)
        let fallback = NWNearbyConfiguration.chatInstanceName(displayName: "\u{200B}")
        #expect(fallback.hasPrefix(NWNearbyConfiguration.instanceNamePrefix))
        // Share keeps random instance names.
        #expect(NWNearbyTransport.advertising().serviceName?.hasPrefix(NWNearbyConfiguration.instanceNamePrefix) == true)
    }

    @Test func browsedNamesAreSanitizedForDisplay() {
        let endpoint = NearbyEndpointModel(
            id: "Mallory\u{202E}cod.exe",
            endpoint: .hostPort(host: "localhost", port: 1)
        )
        #expect(endpoint.displayName == "Mallorycod.exe")
    }

    @Test func chatTimeoutsAreSeparateFromShare() {
        #expect(NearbyTimeoutKind.chatIdle.duration == Timeouts.chatIdle)
        #expect(NearbyTimeoutKind.keepalive.duration == Timeouts.chatKeepaliveInterval)
        #expect(Timeouts.chatKeepaliveInterval < Timeouts.chatIdle)
        #expect(Limits.chatMessageBytes == 4 * Limits.bytesPerKiB)
        #expect(Limits.chatMessageBytes < NearbyProtocol.maxFramePlaintextBytes)
        #expect(NearbyChatSession.timeoutKind(phase: .chatting, role: .initiator) == .chatIdle)
        #expect(NearbyChatSession.timeoutKind(phase: .comparingCodes, role: .responder) == .sas)
    }
}
