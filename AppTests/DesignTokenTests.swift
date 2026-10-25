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

    /// Every color set in Assets.xcassets with the approved light and dark values (1.0, boards
    /// Main2-Home and Main2-Dark; docs/DESIGN.md "1.0"): black and white, system greys, no brand
    /// blue (Brand is ink), cards as a translucent glass fill.
    nonisolated static let tokens: [Token] = [
        Token(name: "Ground", light: RGBA(0xFFFFFF), dark: RGBA(0x000000)),
        Token(name: "Surface", light: RGBA(0xF5F5F7), dark: RGBA(0x1C1C1E)),
        Token(name: "Surface2", light: RGBA(0xE8E8ED), dark: RGBA(0x2C2C2E)),
        Token(name: "Card", light: RGBA(0xFFFFFF, alpha: 0.80), dark: RGBA(0x1C1C1E, alpha: 0.72)),
        Token(name: "Ink", light: RGBA(0x000000), dark: RGBA(0xFFFFFF)),
        Token(name: "MutedText", light: RGBA(0x3F3F42), dark: RGBA(0xAEAEB2)),
        Token(name: "SubtleText", light: RGBA(0x5C5C61), dark: RGBA(0x8E8E93)),
        Token(name: "FaintText", light: RGBA(0xA1A1A6), dark: RGBA(0x48484A)),
        Token(name: "Hairline", light: RGBA(0x000000, alpha: 0.08), dark: RGBA(0xFFFFFF, alpha: 0.10)),
        Token(name: "HairlineStrong", light: RGBA(0x000000, alpha: 0.16), dark: RGBA(0xFFFFFF, alpha: 0.20)),
        Token(name: "Brand", light: RGBA(0x000000), dark: RGBA(0xFFFFFF)),
        Token(name: "Warning", light: RGBA(0x8A6316), dark: RGBA(0xD9A441)),
        Token(name: "Success", light: RGBA(0x1F7A55), dark: RGBA(0x3FB283)),
        Token(name: "Danger", light: RGBA(0xCA2121), dark: RGBA(0xEC6A6A)),
        Token(name: "InkBadge", light: RGBA(0xFFFFFF, alpha: 0.20), dark: RGBA(0x000000, alpha: 0.12)),
        Token(name: "DotGrid", light: RGBA(0x000000, alpha: 0.12), dark: RGBA(0xFFFFFF, alpha: 0.10)),
        Token(name: "Shadow", light: RGBA(0x000000, alpha: 0.12), dark: RGBA(0x000000, alpha: 0.40)),
        // The notch island continues the hardware notch: black in both appearances (board NotchUnlock).
        Token(name: "Island", light: RGBA(0x000000), dark: RGBA(0x000000)),
        Token(name: "IslandInk", light: RGBA(0xFFFFFF), dark: RGBA(0xFFFFFF)),
        Token(name: "IslandMuted", light: RGBA(0xFFFFFF, alpha: 0.60), dark: RGBA(0xFFFFFF, alpha: 0.60)),
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

    /// The global accent color (focus rings, selection, toggles) is Brand, which 1.0 makes ink.
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
        #expect(Theme.Layout.tableRowHeight == 34)
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
        #expect(Theme.TextStyle.sectionLabel.isUppercase)
        #expect(abs(Theme.TextStyle.sectionLabel.tracking - 0.88) < 0.0001)
        #expect(!Theme.TextStyle.body.isUppercase)
        #expect(Theme.TextStyle.body.tracking == 0)
        // SF Pro tracks itself by size; 1.0 adds none to headings.
        for style in [Theme.TextStyle.display, .largeTitle, .title, .title2, .headline] {
            #expect(style.tracking == 0)
        }
    }

    // MARK: Fonts

    /// 1.0 type scale (docs/DESIGN.md "1.0"): body 13, secondary 12, labels 11, titles 22–24.
    @Test func typeScaleFollowsTheOnePointZeroDesign() {
        #expect(Theme.Typography.Size.body == 13)
        #expect(Theme.Typography.Size.caption == 12)
        #expect(Theme.Typography.Size.label == 11)
        #expect(Theme.Typography.Size.title == 22)
        #expect(Theme.Typography.Size.largeTitle == 24)
    }

    /// The UI uses the system faces: no font files ship, and Info.plist registers none.
    @Test func noBundledFontsShip() throws {
        #expect(Bundle.main.object(forInfoDictionaryKey: "ATSApplicationFontsPath") == nil)
        let resources = try #require(Bundle.main.resourceURL)
        let files = try FileManager.default.contentsOfDirectory(atPath: resources.path)
        #expect(!files.contains { $0.hasSuffix(".ttf") || $0.hasSuffix(".otf") })
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
