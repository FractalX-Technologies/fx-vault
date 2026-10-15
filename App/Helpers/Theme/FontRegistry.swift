import AppKit
import CoreText
import SwiftUI

/// The bundled Geist faces (OFL 1.1, App/Resources/Fonts) and their fallback.
///
/// The app registers them through `ATSApplicationFontsPath` in Info.plist (project.yml), so they
/// are available before the first view is built. If a face is missing anyway (a stripped bundle,
/// a font the system refused), ``FontRegistry`` registers the bundled file itself, and when that
/// fails too, ``font(_:size:relativeTo:)`` returns the system font with the same weight and
/// design: the UI degrades to SF Pro / SF Mono instead of to Helvetica or a crash.
nonisolated enum FontRegistry {
    /// The faces FX Vault ships: Geist Sans and Geist Mono at 400, 500 and 600.
    enum Face: String, CaseIterable, Sendable {
        case sansRegular = "Geist-Regular"
        case sansMedium = "Geist-Medium"
        case sansSemibold = "Geist-SemiBold"
        case monoRegular = "GeistMono-Regular"
        case monoMedium = "GeistMono-Medium"
        case monoSemibold = "GeistMono-SemiBold"

        /// The PostScript name, which is also the bundled file's base name (`.ttf`).
        var postScriptName: String { rawValue }

        var isMonospaced: Bool {
            switch self {
            case .monoRegular, .monoMedium, .monoSemibold: true
            case .sansRegular, .sansMedium, .sansSemibold: false
            }
        }

        /// The weight of the system font used when this face is unavailable.
        var weight: Font.Weight {
            switch self {
            case .sansRegular, .monoRegular: .regular
            case .sansMedium, .monoMedium: .medium
            case .sansSemibold, .monoSemibold: .semibold
            }
        }

        /// The Geist face for a weight (400, 500 or 600; anything heavier maps to 600).
        static func sans(_ weight: Font.Weight) -> Face {
            switch weight {
            case .medium: .sansMedium
            case .semibold, .bold, .heavy, .black: .sansSemibold
            default: .sansRegular
            }
        }

        /// The Geist Mono face for a weight (400, 500 or 600).
        static func mono(_ weight: Font.Weight) -> Face {
            switch weight {
            case .medium: .monoMedium
            case .semibold, .bold, .heavy, .black: .monoSemibold
            default: .monoRegular
            }
        }
    }

    /// The bundled font file type.
    static let fileExtension = "ttf"
    /// Where the files live in the repository (copied flat into Contents/Resources).
    static let sourceSubdirectory = "Fonts"

    /// Faces that resolved at launch. Computed once; registers bundled files that ATS did not.
    static let availableFaces: Set<Face> = {
        var available = Set(Face.allCases.filter(isInstalled))
        for face in Face.allCases where !available.contains(face) {
            if registerBundledFile(for: face), isInstalled(face) {
                available.insert(face)
            }
        }
        if available.count < Face.allCases.count {
            let missing = Face.allCases.filter { !available.contains($0) }.map(\.rawValue)
            AppLog.ui.error("Geist faces missing, using system fonts: \(missing.joined(separator: ", "), privacy: .public)")
        }
        return available
    }()

    /// The faces that fell back to the system font (empty in a healthy bundle).
    static var missingFaces: [Face] {
        Face.allCases.filter { !availableFaces.contains($0) }
    }

    static func isAvailable(_ face: Face) -> Bool {
        availableFaces.contains(face)
    }

    /// The Geist face at `size`, scaled relative to `textStyle`, or the matching system font
    /// when the face is unavailable.
    static func font(_ face: Face, size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        font(face, size: size, relativeTo: textStyle, isAvailable: isAvailable(face))
    }

    /// The resolution rule, separated for tests.
    static func font(_ face: Face, size: CGFloat, relativeTo textStyle: Font.TextStyle, isAvailable: Bool) -> Font {
        if isAvailable {
            return Font.custom(face.postScriptName, size: size, relativeTo: textStyle)
        }
        return Font.system(size: size, weight: face.weight, design: face.isMonospaced ? .monospaced : .default)
    }

    /// The Geist face as an `NSFont` for AppKit views, or the matching system font when the face
    /// is unavailable.
    static func nsFont(_ face: Face, size: CGFloat) -> NSFont {
        if isAvailable(face), let font = NSFont(name: face.postScriptName, size: size) {
            return font
        }
        let weight = nsWeight(for: face.weight)
        return face.isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func nsWeight(for weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .medium: .medium
        case .semibold: .semibold
        default: .regular
        }
    }

    /// The bundled file of a face, if the app bundle contains it.
    static func bundledFileURL(for face: Face, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: face.postScriptName, withExtension: fileExtension)
            ?? bundle.url(forResource: face.postScriptName, withExtension: fileExtension, subdirectory: sourceSubdirectory)
    }

    private static func isInstalled(_ face: Face) -> Bool {
        NSFont(name: face.postScriptName, size: NSFont.systemFontSize) != nil
    }

    private static func registerBundledFile(for face: Face) -> Bool {
        guard let url = bundledFileURL(for: face) else { return false }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        error?.release()
        return registered
    }
}
