import SwiftUI

/// The FractalX 3×3 mark drawn with SwiftUI shapes (mockup Brand): eight filled squares around
/// an empty center. FX Vault's variant outlines the center cell in the brand blue: the vault.
///
/// ```swift
/// BrandMark()                                                      // 18 pt, ink, empty center
/// BrandMark(size: Theme.Layout.brandMarkLarge, center: .outlined)  // lock and onboarding
/// ```
///
/// The app icon (scripts/make-icon.swift) draws the same geometry with Core Graphics.
struct BrandMark: View {
    enum Center: Sendable {
        /// The FractalX mark: the center cell is empty.
        case empty
        /// FX Vault: the center cell is a brand-blue outline.
        case outlined
    }

    let size: CGFloat
    let color: Color
    let center: Center

    init(size: CGFloat = Theme.Layout.brandMarkSmall, color: Color = Theme.Colors.ink, center: Center = .empty) {
        self.size = size
        self.color = color
        self.center = center
    }

    var body: some View {
        ZStack {
            BrandMarkCellsShape()
                .fill(color)
            if center == .outlined {
                BrandMarkCenterShape()
                    .stroke(Theme.Colors.brand, lineWidth: size * Geometry.strokeFraction)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "brand.mark.accessibility", defaultValue: "FractalX"))
        .accessibilityAddTraits(.isImage)
    }

    /// The mark's geometry, in fractions of its size (the mockup's 3×3 viewBox: 0.86 cells on
    /// a 1.07 pitch, a 0.09 center stroke).
    nonisolated enum Geometry {
        static let gridUnits: CGFloat = 3
        static let cellFraction: CGFloat = 0.86 / gridUnits
        static let pitchFraction: CGFloat = 1.07 / gridUnits
        static let strokeFraction: CGFloat = Theme.Stroke.brandMarkCenterFraction
        static let centerIndex = 4

        /// The nine cells, row by row, in a square `rect`.
        static func cells(in rect: CGRect) -> [CGRect] {
            let side = min(rect.width, rect.height)
            let cell = side * cellFraction
            let pitch = side * pitchFraction
            return (0..<9).map { index in
                CGRect(
                    x: rect.minX + CGFloat(index % 3) * pitch,
                    y: rect.minY + CGFloat(index / 3) * pitch,
                    width: cell,
                    height: cell
                )
            }
        }

        /// The eight filled cells (every cell but the center).
        static func filledCells(in rect: CGRect) -> [CGRect] {
            cells(in: rect).enumerated().filter { $0.offset != centerIndex }.map(\.element)
        }

        static func centerCell(in rect: CGRect) -> CGRect {
            cells(in: rect)[centerIndex]
        }
    }
}

/// The eight filled squares of ``BrandMark``.
nonisolated struct BrandMarkCellsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for cell in BrandMark.Geometry.filledCells(in: rect) {
            path.addRect(cell)
        }
        return path
    }
}

/// The center square of ``BrandMark`` (stroked in the brand blue).
nonisolated struct BrandMarkCenterShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(BrandMark.Geometry.centerCell(in: rect))
    }
}

#Preview {
    HStack(spacing: Theme.Spacing.xxLarge) {
        BrandMark()
        BrandMark(size: Theme.Layout.brandMarkLarge)
        BrandMark(size: Theme.Layout.brandMarkLarge, center: .outlined)
    }
    .padding(Theme.Spacing.xxLarge)
    .background(Theme.Colors.ground)
}
