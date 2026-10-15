import os

/// App loggers (§4.5). Never log values, tokens, passwords, recovery keys or passphrases;
/// names only with `privacy: .private`.
nonisolated enum AppLog {
    /// One subsystem for both build identities (the category tells areas apart; Debug and
    /// Release logs differ by process name).
    static let subsystem = AppIdentity.releaseBundleIdentifier
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let vault = Logger(subsystem: subsystem, category: "vault")
}
