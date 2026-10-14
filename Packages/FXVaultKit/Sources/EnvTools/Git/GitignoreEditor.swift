import Foundation

/// Pure helpers for offering a `.gitignore` entry after a `.env` export (§5.13, §8 D5).
///
/// These do **not** evaluate gitignore globs: whether git ignores a path is decided by
/// `git check-ignore` (``GitignoreChecker``). They build the exact line to append and avoid
/// appending a line that is already there.
public enum GitignoreEditor {
    /// The file name git reads at the work tree root.
    public static let fileName = ".gitignore"
    private static let anchor: Character = "/"
    private static let globStar = "**/"
    private static let escape: Character = "\\"
    private static let commentStart: Character = "#"
    private static let negation: Character = "!"
    /// Characters that are glob syntax in a gitignore pattern.
    private static let globCharacters: Set<Character> = ["*", "?", "[", "\\"]

    /// `<root>/.gitignore`.
    public static func gitignoreURL(repositoryRoot root: URL) -> URL {
        root.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// `fileURL`'s path relative to `root` with `/` separators, or nil when it is not inside
    /// `root`. Symbolic links are resolved on both sides (git prints the resolved root).
    public static func relativePath(of fileURL: URL, toRepositoryRoot root: URL) -> String? {
        let file = PathResolver.resolvedPath(of: fileURL)
        let rootPath = PathResolver.resolvedPath(of: root)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard file.hasPrefix(prefix), file.count > prefix.count else { return nil }
        return String(file.dropFirst(prefix.count))
    }

    /// The line that ignores exactly `relativePath`: anchored with a leading `/`, glob
    /// characters (`* ? [ \`) escaped, trailing spaces escaped. Nil when the path is empty or
    /// contains a line break (it cannot be written as a pattern).
    ///
    /// Example: `config/.env.production` → `/config/.env.production`.
    public static func ignoreLine(forRelativePath relativePath: String) -> String? {
        guard !relativePath.isEmpty, !relativePath.contains(where: \.isNewline) else { return nil }
        return String(anchor) + escaped(relativePath)
    }

    /// True when `contents` already has a line equivalent to the exact entry for `relativePath`:
    /// `/<path>`, or `<path>` / `**/<path>` (for a path with no `/`), or `<path>` (for a path
    /// with a `/`, which git anchors anyway). Comments, blank lines and negations are skipped.
    public static func containsEntry(forRelativePath relativePath: String, in contents: String) -> Bool {
        lastEntryIndex(forRelativePath: relativePath, in: patternLines(of: contents)) != nil
    }

    /// `existing` (nil when there is no `.gitignore`) with `line` appended on its own line, or
    /// nil when nothing needs to change: an equivalent entry exists and no negation (`!...`)
    /// follows it. A later negation could re-include the file, so the line is appended again
    /// at the end, where it wins.
    public static func contents(
        byAddingEntryForRelativePath relativePath: String,
        to existing: String?
    ) -> String? {
        guard let line = ignoreLine(forRelativePath: relativePath) else { return nil }
        let current = existing ?? ""
        let lines = patternLines(of: current)
        if let index = lastEntryIndex(forRelativePath: relativePath, in: lines),
           !lines[(index + 1)...].contains(where: { $0.first == negation }) {
            return nil
        }
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        return current + separator + line + "\n"
    }

    // MARK: - Internals

    private static func escaped(_ path: String) -> String {
        var result = ""
        for character in path {
            if globCharacters.contains(character) { result.append(escape) }
            result.append(character)
        }
        // Git strips unescaped trailing spaces from patterns.
        var trailingSpaces = 0
        while result.hasSuffix(" ") {
            result.removeLast()
            trailingSpaces += 1
        }
        result += String(repeating: "\\ ", count: trailingSpaces)
        return result
    }

    /// Non-blank, non-comment lines with unescaped trailing whitespace removed (negations kept).
    private static func patternLines(of contents: String) -> [String] {
        contents
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { trimmingUnescapedTrailingWhitespace(String($0)) }
            .filter { !$0.isEmpty && $0.first != commentStart }
    }

    private static func lastEntryIndex(forRelativePath relativePath: String, in lines: [String]) -> Int? {
        let pattern = escaped(relativePath)
        var equivalents: Set<String> = [String(anchor) + pattern, pattern]
        if !relativePath.contains(anchor) {
            equivalents.insert(globStar + pattern)
        }
        return lines.lastIndex { equivalents.contains($0) }
    }

    private static func trimmingUnescapedTrailingWhitespace(_ line: String) -> String {
        var result = line
        while let last = result.last, last == " " || last == "\t" {
            let beforeLast = result.dropLast()
            if beforeLast.last == escape { break }
            result.removeLast()
        }
        return result
    }
}
