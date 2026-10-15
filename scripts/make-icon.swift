// make-icon.swift - draws the FX Vault app icon and writes a complete macOS AppIcon set.
//
// Usage: swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
//
// The approved FractalX icon (docs/design/mockup/Brand.dc.html, docs/DESIGN.md "App icon"):
// a dark #0B0C0E rounded square on Apple's 1024-point macOS grid (824-point tile, standard
// padding and drop shadow), the off-white #F6F5F3 FractalX 3x3 mark, and its center cell as a
// brand-blue #3BA3DD outlined square: the vault. Vector-drawn with Core Graphics (no SF Symbols,
// whose license excludes app icons); every size is rendered from the vector, not downscaled.
// The mark geometry matches BrandMark.Geometry in the app. Output is deterministic.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Grid {
    static let canvas: CGFloat = 1024
    static let tileInset: CGFloat = 100      // Apple macOS icon template: 824-point tile
    static let tileRadius: CGFloat = 185
    static let shadowBlur: CGFloat = 28
    static let shadowOffsetY: CGFloat = -12
    static let shadowAlpha: CGFloat = 0.3
    static let edgeStrokeWidth: CGFloat = 2
    static let edgeStrokeAlpha: CGFloat = 0.08
}

/// The FractalX mark in the mockup's 3x3 viewBox: 0.86 cells on a 1.07 pitch, a 0.09 stroke.
enum Mark {
    /// The mark's side as a fraction of the tile (mockup: 84 of 160).
    static let tileFraction: CGFloat = 84.0 / 160.0
    static let gridUnits: CGFloat = 3
    static let cell: CGFloat = 0.86
    static let pitch: CGFloat = 1.07
    static let centerStroke: CGFloat = 0.09
    static let centerIndex = 4
}

struct RGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    init(hex: UInt32) {
        let max: CGFloat = 255
        red = CGFloat((hex >> 16) & 0xFF) / max
        green = CGFloat((hex >> 8) & 0xFF) / max
        blue = CGFloat(hex & 0xFF) / max
    }

    func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

enum Palette {
    static let tile = RGB(hex: 0x0B_0C_0E)      // Ink
    static let mark = RGB(hex: 0xF6_F5_F3)      // Ground
    static let center = RGB(hex: 0x3B_A3_DD)    // Brand (dark)
}

struct IconSize {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var filename: String {
        scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png"
    }
}

let sizes: [IconSize] = [16, 32, 128, 256, 512].flatMap { points in
    [IconSize(points: points, scale: 1), IconSize(points: points, scale: 2)]
}

/// The nine cells of the mark, row by row from the top, centered in `tile`.
func markCells(in tile: CGRect) -> [CGRect] {
    let side = tile.width * Mark.tileFraction
    let unit = side / Mark.gridUnits
    let origin = CGPoint(x: tile.midX - side / 2, y: tile.midY - side / 2)
    return (0..<9).map { index in
        let column = CGFloat(index % 3)
        let row = CGFloat(index / 3)
        // Core Graphics has a bottom-left origin: the first row is the top one.
        return CGRect(
            x: origin.x + column * Mark.pitch * unit,
            y: origin.y + side - (row * Mark.pitch + Mark.cell) * unit,
            width: Mark.cell * unit,
            height: Mark.cell * unit
        )
    }
}

func drawIcon(in context: CGContext) {
    let tileRect = CGRect(x: 0, y: 0, width: Grid.canvas, height: Grid.canvas)
        .insetBy(dx: Grid.tileInset, dy: Grid.tileInset)
    let tile = CGPath(roundedRect: tileRect, cornerWidth: Grid.tileRadius, cornerHeight: Grid.tileRadius, transform: nil)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: Grid.shadowOffsetY),
        blur: Grid.shadowBlur,
        color: CGColor(gray: 0, alpha: Grid.shadowAlpha)
    )
    context.addPath(tile)
    context.setFillColor(Palette.tile.cgColor())
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.setStrokeColor(CGColor(gray: 1, alpha: Grid.edgeStrokeAlpha))
    context.setLineWidth(Grid.edgeStrokeWidth)
    context.strokePath()
    context.restoreGState()

    let cells = markCells(in: tileRect)
    context.setFillColor(Palette.mark.cgColor())
    for (index, cell) in cells.enumerated() where index != Mark.centerIndex {
        context.fill(cell)
    }

    let unit = tileRect.width * Mark.tileFraction / Mark.gridUnits
    context.setStrokeColor(Palette.center.cgColor())
    context.setLineWidth(Mark.centerStroke * unit)
    context.stroke(cells[Mark.centerIndex])
}

enum IconError: Error {
    case usage
    case context(Int)
    case write(String)
}

func render(_ size: IconSize, to directory: URL) throws {
    let pixels = size.pixels
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw IconError.context(pixels) }
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    let factor = CGFloat(pixels) / Grid.canvas
    context.scaleBy(x: factor, y: factor)
    drawIcon(in: context)

    let url = directory.appendingPathComponent(size.filename)
    guard
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError.write(size.filename) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.write(size.filename) }
}

func writeContents(to directory: URL) throws {
    let images: [[String: String]] = sizes.map { size in
        [
            "filename": size.filename,
            "idiom": "mac",
            "scale": "\(size.scale)x",
            "size": "\(size.points)x\(size.points)",
        ]
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    var data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    data.append(contentsOf: Array("\n".utf8))
    try data.write(to: directory.appendingPathComponent("Contents.json"))
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <AppIcon.appiconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in sizes {
    try render(size, to: output)
}
try writeContents(to: output)
