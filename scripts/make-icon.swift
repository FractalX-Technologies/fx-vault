// make-icon.swift - draws the FX Vault app icon and writes a complete macOS AppIcon set.
//
// Usage: swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
//
// The icon is vector-drawn with Core Graphics (no SF Symbols, whose license excludes
// app icons): a dark rounded square on Apple's 1024-point macOS grid with an accent
// shield and a keyhole. Every size is rendered from the vector, not downscaled.
// Output is deterministic, so re-running it produces identical files.

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
    static let strokeWidth: CGFloat = 2
    static let strokeAlpha: CGFloat = 0.08
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
    static let tileTop = RGB(hex: 0x24_24_2E)
    static let tileBottom = RGB(hex: 0x0E_0E_13)
    static let shieldTop = RGB(hex: 0x9B_9D_FA)
    static let shieldBottom = RGB(hex: 0x5B_5B_D6)
    static let keyhole = RGB(hex: 0x12_12_18)
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

/// Builds the shield outline in a top-left-origin 1024 space, flipped for Core Graphics.
func shieldPath() -> CGPath {
    let path = CGMutablePath()
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: Grid.canvas - y) }
    path.move(to: p(512, 236))
    path.addCurve(to: p(728, 312), control1: p(586, 290), control2: p(660, 312))
    path.addLine(to: p(728, 500))
    path.addCurve(to: p(512, 800), control1: p(728, 646), control2: p(628, 744))
    path.addCurve(to: p(296, 500), control1: p(396, 744), control2: p(296, 646))
    path.addLine(to: p(296, 312))
    path.addCurve(to: p(512, 236), control1: p(364, 312), control2: p(438, 290))
    path.closeSubpath()
    return path
}

/// The keyhole as two shapes (head and stem), each filled on its own so their
/// overlap never cancels out under the nonzero winding rule.
func keyholePaths() -> [CGPath] {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: Grid.canvas - y) }
    let radius: CGFloat = 64
    let head = CGPath(
        ellipseIn: CGRect(x: 512 - radius, y: Grid.canvas - 470 - radius, width: radius * 2, height: radius * 2),
        transform: nil
    )
    let stem = CGMutablePath()
    stem.move(to: p(484, 480))
    stem.addLine(to: p(540, 480))
    stem.addLine(to: p(566, 652))
    stem.addLine(to: p(458, 652))
    stem.closeSubpath()
    return [head, stem]
}

func drawIcon(in context: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
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
    context.setFillColor(Palette.tileBottom.cgColor())
    context.fillPath()
    context.restoreGState()

    func fillGradient(_ path: CGPath, top: RGB, bottom: RGB, from: CGFloat, to: CGFloat) {
        let colors = [top.cgColor(), bottom.cgColor()] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: Grid.canvas / 2, y: from),
            end: CGPoint(x: Grid.canvas / 2, y: to),
            options: []
        )
        context.restoreGState()
    }

    fillGradient(tile, top: Palette.tileTop, bottom: Palette.tileBottom, from: tileRect.maxY, to: tileRect.minY)

    context.saveGState()
    context.addPath(tile)
    context.setStrokeColor(CGColor(gray: 1, alpha: Grid.strokeAlpha))
    context.setLineWidth(Grid.strokeWidth)
    context.strokePath()
    context.restoreGState()

    let shield = shieldPath()
    fillGradient(shield, top: Palette.shieldTop, bottom: Palette.shieldBottom, from: shield.boundingBox.maxY, to: shield.boundingBox.minY)

    context.setFillColor(Palette.keyhole.cgColor())
    for part in keyholePaths() {
        context.addPath(part)
        context.fillPath()
    }
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
