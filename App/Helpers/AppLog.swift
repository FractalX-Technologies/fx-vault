import os

/// App loggers (§4.5). Never log values, tokens, passwords, recovery keys or passphrases;
/// names only with `privacy: .private`.
nonisolated enum AppLog {
    static let subsystem = "io.fractalx.fxvault"
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let vault = Logger(subsystem: subsystem, category: "vault")
}
