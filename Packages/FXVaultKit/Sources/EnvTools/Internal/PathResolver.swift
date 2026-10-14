import Darwin
import Foundation

/// Resolves paths for comparisons with git's `rev-parse --show-toplevel` output and with the
/// iCloud folders: symbolic links in the nearest existing ancestor are resolved with
/// `realpath(3)` (so `/var` becomes `/private/var`), and components that do not exist yet (the
/// file about to be written) are appended unchanged.
enum PathResolver {
    static func resolvedPath(of url: URL) -> String {
        let standardized = (url.standardizedFileURL.path(percentEncoded: false) as NSString).standardizingPath
        var existing = standardized
        var missingComponents: [String] = []
        while true {
            if let real = realPath(existing) {
                return missingComponents.reversed().reduce(real) { path, component in
                    (path as NSString).appendingPathComponent(component)
                }
            }
            let parent = (existing as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != existing else { return standardized }
            missingComponents.append((existing as NSString).lastPathComponent)
            existing = parent
        }
    }

    /// The nearest ancestor of `url` (or `url` itself) that exists.
    static func nearestExistingURL(of url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path(percentEncoded: false) != candidate.path(percentEncoded: false) else {
                return nil
            }
            candidate = parent
        }
    }

    /// True when `path` is `base` or inside it. Case-insensitive, like the default APFS volume;
    /// on a case-sensitive volume this can only add warnings, never hide one.
    ///
    /// Both paths must already be resolved: `standardizingPath` is deliberately not applied here,
    /// because it strips the `/private` prefix that `realpath(3)` adds.
    static func isPath(_ path: String, within base: String) -> Bool {
        let path = path.lowercased()
        let base = base.lowercased()
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
