import Darwin
import Foundation
import VaultCore

/// One concrete `Host` alias from the user's ssh configuration.
public struct SSHHostEntryModel: Sendable, Hashable, Identifiable {
    public let alias: String
    /// The first `HostName` that applies to the alias, if any.
    public let hostName: String?
    /// The first `User` that applies, if any.
    public let user: String?
    /// The file that declared the alias first.
    public let sourcePath: String

    public init(alias: String, hostName: String?, user: String?, sourcePath: String) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.sourcePath = sourcePath
    }

    public var id: String {
        alias
    }

    /// True when the configuration maps the alias to github.com (case-insensitive), or the
    /// alias is `github.com` itself with no `HostName`. Only a hint: ``SSHAliasResolver``'s
    /// `ssh -G` is authoritative (§8 D1).
    public var looksLikeGitHub: Bool {
        (hostName ?? alias).lowercased() == GHConstants.host
    }
}

/// Lists concrete `Host` aliases from `~/.ssh/config` (tasks/todo.md §8 D, M2).
///
/// - Keywords are case-insensitive; arguments may follow whitespace or `=`; double-quoted
///   arguments may contain spaces; `#` starts a comment line.
/// - `Host a b c` declares several aliases. Patterns with `*`, `?` or `!` are skipped, as are
///   aliases that fail ``SSHAliasValidator`` (for example one starting with `-`).
/// - `Match` blocks end the current `Host` block (their directives are not attributed).
/// - `Include` accepts several glob patterns; relative paths are relative to `~/.ssh`, `~` is
///   expanded, matches are read in lexical order, up to ``maxIncludeDepth`` levels, never the
///   same file twice.
/// - For each alias the first `HostName` and `User` win, as in ssh.
public struct SSHConfigParser: Sendable {
    /// ssh's own Include depth limit.
    public static let maxIncludeDepth = 16
    /// Files larger than this are ignored.
    public static let maxFileBytes = Limits.bytesPerMiB
    /// At most this many files are read in one parse.
    public static let maxFiles = 256

    private let sshDirectory: URL
    private let homeDirectory: URL

    /// `sshDirectory` is `~/.ssh`; `homeDirectory` expands `~`.
    public init(sshDirectory: URL, homeDirectory: URL) {
        self.sshDirectory = sshDirectory
        self.homeDirectory = homeDirectory
    }

    /// The parser for the current user's `~/.ssh`.
    public static func forUser(_ identity: ProcessIdentityModel) -> SSHConfigParser {
        let home = URL(fileURLWithPath: identity.home, isDirectory: true)
        return SSHConfigParser(sshDirectory: home.appendingPathComponent(".ssh", isDirectory: true), homeDirectory: home)
    }

    /// Parses `~/.ssh/config` (empty when it does not exist).
    public func parseUserConfig() -> [SSHHostEntryModel] {
        parse(fileAt: sshDirectory.appendingPathComponent("config"))
    }

    /// Parses one file and everything it includes.
    public func parse(fileAt url: URL) -> [SSHHostEntryModel] {
        var state = ParseState()
        parseFile(url.path, depth: 0, state: &state)
        return state.entries()
    }

    /// Parses text (Includes are resolved against the file system).
    public func parse(contents: String, sourcePath: String) -> [SSHHostEntryModel] {
        var state = ParseState()
        parseText(contents, sourcePath: sourcePath, depth: 0, state: &state)
        return state.entries()
    }

    // MARK: - Parsing

    private struct Accumulated {
        var hostName: String?
        var user: String?
        let sourcePath: String
    }

    private struct ParseState {
        var order: [String] = []
        var byAlias: [String: Accumulated] = [:]
        var currentAliases: [String] = []
        var visitedFiles: Set<String> = []

        mutating func declare(_ aliases: [String], sourcePath: String) {
            currentAliases = aliases
            for alias in aliases where byAlias[alias] == nil {
                byAlias[alias] = Accumulated(sourcePath: sourcePath)
                order.append(alias)
            }
        }

        mutating func apply(_ update: (inout Accumulated) -> Void) {
            for alias in currentAliases {
                guard var value = byAlias[alias] else { continue }
                update(&value)
                byAlias[alias] = value
            }
        }

        func entries() -> [SSHHostEntryModel] {
            order.compactMap { alias in
                byAlias[alias].map {
                    SSHHostEntryModel(alias: alias, hostName: $0.hostName, user: $0.user, sourcePath: $0.sourcePath)
                }
            }
        }
    }

    private func parseFile(_ path: String, depth: Int, state: inout ParseState) {
        guard depth <= Self.maxIncludeDepth, state.visitedFiles.count < Self.maxFiles else { return }
        let canonical = (path as NSString).resolvingSymlinksInPath
        guard state.visitedFiles.insert(canonical).inserted else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: canonical),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= Self.maxFileBytes,
              let data = FileManager.default.contents(atPath: canonical)
        else { return }
        parseText(String(decoding: data, as: UTF8.self), sourcePath: canonical, depth: depth, state: &state)
    }

    private func parseText(_ text: String, sourcePath: String, depth: Int, state: inout ParseState) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let (keyword, arguments) = Self.split(line) else { continue }
            switch keyword {
            case "host":
                let aliases = arguments.filter { !Self.isPattern($0) && SSHAliasValidator.isValid($0) }
                state.declare(aliases, sourcePath: sourcePath)
            case "match":
                state.currentAliases = []
            case "hostname":
                guard let value = arguments.first else { continue }
                state.apply { if $0.hostName == nil { $0.hostName = value } }
            case "user":
                guard let value = arguments.first else { continue }
                state.apply { if $0.user == nil { $0.user = value } }
            case "include":
                for pattern in arguments {
                    for path in expandInclude(pattern) {
                        parseFile(path, depth: depth + 1, state: &state)
                    }
                }
            default:
                continue
            }
        }
    }

    /// Splits `Keyword args` / `Keyword=args` into a lowercase keyword and its arguments
    /// (double quotes group words; the quotes are removed).
    static func split(_ line: String) -> (keyword: String, arguments: [String])? {
        guard let keywordEnd = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (line.lowercased(), [])
        }
        let keyword = line[line.startIndex..<keywordEnd].lowercased()
        var rest = line[keywordEnd...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" {
            rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        }
        return (keyword, tokenize(rest))
    }

    static func tokenize(_ text: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if (character == " " || character == "\t") && !inQuotes {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken {
            tokens.append(current)
        }
        return tokens
    }

    private static func isPattern(_ alias: String) -> Bool {
        alias.contains("*") || alias.contains("?") || alias.hasPrefix("!")
    }

    private func expandInclude(_ pattern: String) -> [String] {
        var expanded = pattern
        if expanded == "~" || expanded.hasPrefix("~/") {
            expanded = homeDirectory.path + expanded.dropFirst()
        } else if !expanded.hasPrefix("/") {
            expanded = sshDirectory.appendingPathComponent(expanded).path
        }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(expanded, 0, nil, &result) == 0 else { return [] }
        var paths: [String] = []
        for index in 0..<Int(result.gl_matchc) {
            if let path = result.gl_pathv[index] {
                paths.append(String(cString: path))
            }
        }
        return paths.sorted()
    }
}
