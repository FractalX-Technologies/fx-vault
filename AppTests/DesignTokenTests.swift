import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FXVault

/// v0.3.0 design foundation: color tokens, fonts and the app icon (docs/DESIGN.md).
@MainActor
@Suite("Design tokens")
struct DesignTokenTests {
    /// An sRGB color with alpha, written as in the mockup (`#RRGGBB` plus opacity).
    struct RGBA: CustomStringConvertible, Sendable {
        let hex: UInt32
        let alpha: Double

        init(_ hex: UInt32, alpha: Double = 1) {
            self.hex = hex
            self.alpha = alpha
        }

        var red: Double { Double((hex >> 16) & 0xFF) / 255 }
        var green: Double { Double((hex >> 8) & 0xFF) / 255 }
        var blue: Double { Double(hex & 0xFF) / 255 }
        var description: String { String(format: "#%06X @ %.2f", hex, alpha) }
    }

    struct Token: CustomTestStringConvertible, Sendable {
        let name: String
        let light: RGBA
        let dark: RGBA
        var testDescription: String { name }
    }

    /// Every color set in Assets.xcassets with the approved light and dark values (mockup Main,
    /// MainDark, Brand; tasks/todo.md "v0.3.0: FractalX design language").
    nonisolated static let tokens: [Token] = [
        Token(name: "Ground", light: RGBA(0xF6F5F3), dark: RGBA(0x0B0C0E)),
        Token(name: "Surface", light: RGBA(0xEDEBE7), dark: RGBA(0x111820)),
        Token(name: "Surface2", light: RGBA(0xE4E1DB), dark: RGBA(0x18212A)),
        Token(name: "Card", light: RGBA(0xFFFFFF), dark: RGBA(0x111820)),
        Token(name: "Ink", light: RGBA(0x0B0C0E), dark: RGBA(0xF6F5F3)),
        Token(name: "MutedText", light: RGBA(0x454D56), dark: RGBA(0xA6B0BC)),
        Token(name: "SubtleText", light: RGBA(0x5F6874), dark: RGBA(0x808B97)),
        Token(name: "FaintText", light: RGBA(0xA1A7AF), dark: RGBA(0x4A5460)),
        Token(name: "Hairline", light: RGBA(0x0B0C0E, alpha: 0.10), dark: RGBA(0xFFFFFF, alpha: 0.08)),
        Token(name: "HairlineStrong", light: RGBA(0x0B0C0E, alpha: 0.18), dark: RGBA(0xFFFFFF, alpha: 0.16)),
        Token(name: "Brand", light: RGBA(0x0B6FA4), dark: RGBA(0x3BA3DD)),
        Token(name: "Warning", light: RGBA(0x8A6316), dark: RGBA(0xD9A441)),
        Token(name: "Success", light: RGBA(0x1F7A55), dark: RGBA(0x3FB283)),
        Token(name: "Danger", light: RGBA(0xCA2121), dark: RGBA(0xEC6A6A)),
        Token(name: "InkBadge", light: RGBA(0xF6F5F3, alpha: 0.16), dark: RGBA(0x0B0C0E, alpha: 0.12)),
        Token(name: "DotGrid", light: RGBA(0x0B0C0E, alpha: 0.14), dark: RGBA(0xFFFFFF, alpha: 0.10)),
        Token(name: "Shadow", light: RGBA(0x0B0C0E, alpha: 0.16), dark: RGBA(0x000000, alpha: 0.48)),
    ]

    private static let tolerance = 0.5 / 255

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func resolve(_ color: NSColor, in appearanceName: NSAppearance.Name) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: appearanceName))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        return try #require(resolved)
    }

    private static func expect(_ color: NSColor, equals expected: RGBA, _ context: String) {
        #expect(abs(color.redComponent - expected.red) <= tolerance, "\(context) red, expected \(expected)")
        #expect(abs(color.greenComponent - expected.green) <= tolerance, "\(context) green, expected \(expected)")
        #expect(abs(color.blueComponent - expected.blue) <= tolerance, "\(context) blue, expected \(expected)")
        #expect(abs(color.alphaComponent - expected.alpha) <= tolerance, "\(context) alpha, expected \(expected)")
    }

    // MARK: Colors

    @Test(arguments: tokens)
    func colorSetHasTheApprovedLightAndDarkValues(_ token: Token) throws {
        let color = try #require(NSColor(named: token.name), "missing color set \(token.name)")
        Self.expect(try Self.resolve(color, in: .aqua), equals: token.light, "\(token.name) light")
        Self.expect(try Self.resolve(color, in: .darkAqua), equals: token.dark, "\(token.name) dark")
    }

    /// Every color set in the catalog has a dark variant and is covered by `tokens`, so a new
    /// color cannot ship without its dark value and a test.
    @Test func everyColorSetHasADarkVariantAndATest() throws {
        let catalog = Self.repositoryRoot.appendingPathComponent("App/Resources/Assets.xcassets")
        let sets = try FileManager.default.contentsOfDirectory(atPath: catalog.path)
            .filter { $0.hasSuffix(".colorset") }
            .map { String($0.dropLast(".colorset".count)) }
        #expect(Set(sets) == Set(Self.tokens.map(\.name)))
        for name in sets {
            let url = catalog.appendingPathComponent("\(name).colorset/Contents.json")
            let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let colors = try #require(json["colors"] as? [[String: Any]])
            let darkEntries = colors.filter { entry in
                let appearances = entry["appearances"] as? [[String: String]] ?? []
                return appearances.contains { $0["appearance"] == "luminosity" && $0["value"] == "dark" }
            }
            #expect(colors.count == 2, "\(name): one light and one dark entry")
            #expect(darkEntries.count == 1, "\(name): missing dark variant")
        }
    }

    @Test func themeColorsResolveToTheirColorSets() {
        #expect(Theme.Colors.ground == Color(.ground))
        #expect(Theme.Colors.onInk == Theme.Colors.ground)
        #expect(Theme.Colors.pending == Theme.Colors.brand)
        #expect(Theme.Colors.accent == Theme.Colors.brand)
        #expect(Theme.Colors.textPrimary == Theme.Colors.ink)
        #expect(Theme.Colors.textSecondary == Theme.Colors.mutedText)
        #expect(Theme.Colors.background == Theme.Colors.ground)
    }

    /// The global accent color (focus rings, selection, toggles) is the brand blue.
    @Test func globalAccentIsBrand() throws {
        let spec = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(spec.contains("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: Brand"))
    }

    // MARK: Metrics

    @Test func radiiSpacingAndMotionFollowTheDesign() {
        #expect(Theme.Radius.card == 24)
        #expect(Theme.Radius.sheet == 24)
        #expect(Theme.Radius.control == 12)
        #expect(Theme.Radius.row == 10)
        #expect(Theme.Radius.compactRow == 8)
        #expect(Theme.Durations.interaction == 0.14)
        #expect(Theme.Layout.tableRowHeight == 52)
        let spacing = [
            Theme.Spacing.xxSmall, Theme.Spacing.xSmall, Theme.Spacing.smallMinus, Theme.Spacing.small,
            Theme.Spacing.mediumMinus, Theme.Spacing.medium, Theme.Spacing.large, Theme.Spacing.largePlus,
            Theme.Spacing.xLarge, Theme.Spacing.xLargePlus, Theme.Spacing.xxLarge, Theme.Spacing.xxLargePlus,
            Theme.Spacing.xxxLarge, Theme.Spacing.huge, Theme.Spacing.xHuge,
        ]
        #expect(spacing == spacing.sorted(), "the spacing scale is ascending")
        #expect(Set(spacing).count == spacing.count, "no duplicate steps")
    }

    @Test func textStylesCarryTrackingAndCase() {
        #expect(abs(Theme.TextStyle.display.tracking - -1.76) < 0.0001)
        #expect(Theme.TextStyle.sectionLabel.isUppercase)
        #expect(abs(Theme.TextStyle.sectionLabel.tracking - 0.88) < 0.0001)
        #expect(!Theme.TextStyle.body.isUppercase)
        #expect(Theme.TextStyle.body.tracking == 0)
        for style in [Theme.TextStyle.display, .largeTitle, .title, .title2, .headline] {
            #expect(style.tracking < 0, "headings track tighter")
        }
    }

    // MARK: Fonts

    @Test(arguments: FontRegistry.Face.allCases)
    func bundledFaceIsRegistered(_ face: FontRegistry.Face) throws {
        #expect(FontRegistry.isAvailable(face))
        let font = try #require(NSFont(name: face.postScriptName, size: Theme.Typography.Size.body))
        #expect(font.familyName == (face.isMonospaced ? "Geist Mono" : "Geist"))
        #expect(FontRegistry.bundledFileURL(for: face) != nil, "\(face.rawValue).ttf is not in the app bundle")
    }

    @Test func noFaceFellBackToTheSystemFont() {
        #expect(FontRegistry.missingFaces.isEmpty)
    }

    /// The fonts are registered by Info.plist, not only by the FontRegistry safety net.
    @Test func infoPlistRegistersTheFontFolder() throws {
        let path = try #require(Bundle.main.object(forInfoDictionaryKey: "ATSApplicationFontsPath") as? String)
        let resources = try #require(Bundle.main.resourceURL)
        let folder = resources.appendingPathComponent(path).standardizedFileURL
        for face in FontRegistry.Face.allCases {
            let file = folder.appendingPathComponent("\(face.postScriptName).\(FontRegistry.fileExtension)")
            #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) not in \(path)")
        }
    }

    @Test func missingFaceFallsBackToTheMatchingSystemFont() {
        #expect(FontRegistry.font(.sansMedium, size: 15, relativeTo: .headline, isAvailable: false) == .system(size: 15, weight: .medium, design: .default))
        #expect(FontRegistry.font(.monoRegular, size: 13, relativeTo: .body, isAvailable: false) == .system(size: 13, weight: .regular, design: .monospaced))
        #expect(FontRegistry.font(.sansRegular, size: 14, relativeTo: .body, isAvailable: true) == .custom("Geist-Regular", size: 14, relativeTo: .body))
    }

    @Test func weightsMapToTheShippedFaces() {
        #expect(FontRegistry.Face.sans(.regular) == .sansRegular)
        #expect(FontRegistry.Face.sans(.medium) == .sansMedium)
        #expect(FontRegistry.Face.sans(.bold) == .sansSemibold)
        #expect(FontRegistry.Face.sans(.light) == .sansRegular)
        #expect(FontRegistry.Face.mono(.semibold) == .monoSemibold)
    }

    /// OFL 1.1 condition 2: every copy carries the copyright notice and the license.
    @Test func creditsAndBundleCarryTheFontLicense() throws {
        let creditsURL = try #require(Bundle.main.url(forResource: "Credits", withExtension: "rtf"))
        let credits = try NSAttributedString(url: creditsURL, options: [:], documentAttributes: nil).string
        #expect(credits.contains("The Geist Project Authors"))
        #expect(credits.contains("SIL OPEN FONT LICENSE Version 1.1"))
        let license = try #require(Bundle.main.url(forResource: "Geist-OFL", withExtension: "txt"))
        #expect(try String(contentsOf: license, encoding: .utf8).contains("SIL Open Font License, Version 1.1"))
    }

    // MARK: App icon

    @Test func appIconSetIsComplete() throws {
        let set = Self.repositoryRoot.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: set.appendingPathComponent("Contents.json"))) as? [String: Any])
        let images = try #require(json["images"] as? [[String: String]])
        let expected: Set<String> = ["16x16@1x", "16x16@2x", "32x32@1x", "32x32@2x", "128x128@1x", "128x128@2x", "256x256@1x", "256x256@2x", "512x512@1x", "512x512@2x"]
        #expect(Set(images.compactMap { image in image["size"].flatMap { size in image["scale"].map { "\(size)@\($0)" } } }) == expected)
        for image in images {
            let filename = try #require(image["filename"])
            let bitmap = try #require(NSImage(contentsOf: set.appendingPathComponent(filename))?.representations.first)
            let points = try #require(image["size"]?.split(separator: "x").first.flatMap { Int($0) })
            let scale = try #require(image["scale"].flatMap { Int($0.replacingOccurrences(of: "x", with: "")) })
            #expect(bitmap.pixelsWide == points * scale, "\(filename)")
        }
    }
}
