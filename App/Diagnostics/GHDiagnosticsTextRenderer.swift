import Foundation
import GitHubKit

/// The plain-text gh report that **Copy Diagnostics** puts on the clipboard (v0.3.1). It renders
/// the same value-free `GHDiagnosticsModel` as the `gh` section of `--diagnose`: paths, versions,
/// codes, variable names and account logins, never a token or a variable's value.
///
/// Like the `--diagnose` JSON it is a support artifact, not interface text: the labels and the
/// codes stay fixed English so whoever reads it can compare reports, and are not localized.
nonisolated enum GHDiagnosticsTextRenderer {
    static let title = "FX Vault GitHub CLI diagnostics"
    static let privacyLine = "Paths, versions, variable names and account names only: no tokens, secrets or variable values."
    private static let none = "none"
    private static let notFound = "not found"
    private static let chosenMarker = "*"
    private static let otherMarker = "-"
    private static let listSeparator = ", "

    /// The report, starting with the app's version and build.
    static func render(_ model: GHDiagnosticsModel, version: String, build: String) -> String {
        var lines = [
            "\(title): FX Vault \(version) (\(build))",
            privacyLine,
            "",
            "Result: \(model.result)",
            "Chosen gh: \(model.chosenPath ?? none)",
            "gh path override: \(model.overridePath ?? none)",
            "Trusted gh: \(trustedBinary(model.trustedBinary))",
            "",
            "Shell: \(model.shell.path ?? none) (probe: \(model.shell.probeMode.rawValue))",
            "Shell gh (command -v gh): \(model.shell.ghPath ?? none)",
            "Shell variables set: \(list(model.shell.variablesSet))",
            "",
            "Candidates:",
        ]
        let found = model.candidates.filter { $0.status != GHDiagnosticsModel.notFoundStatus }
        lines += found.map(candidate)
        let missing = model.candidates.filter { $0.status == GHDiagnosticsModel.notFoundStatus }.map(\.path)
        if !missing.isEmpty {
            lines.append("\(otherMarker) \(notFound): \(missing.joined(separator: listSeparator))")
        }
        lines.append("")
        lines += accounts(model)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func trustedBinary(_ trust: GHDiagnosticsModel.TrustEntry?) -> String {
        guard let trust else { return none }
        return "\(trust.path) (owner \(owner(name: trust.ownerName, uid: trust.ownerUID)))"
    }

    private static func owner(name: String?, uid: UInt32) -> String {
        name.map { "\($0), uid \(uid)" } ?? "uid \(uid)"
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? none : items.joined(separator: listSeparator)
    }

    private static func candidate(_ entry: GHDiagnosticsModel.CandidateEntry) -> String {
        var text = "\(entry.isChosen ? chosenMarker : otherMarker) \(entry.path) [\(entry.source.rawValue)]"
        if let resolved = entry.resolvedPath, resolved != entry.path {
            text += " -> \(resolved)"
        }
        text += ": \(entry.status)"
        var details: [String] = []
        if let reason = entry.reason {
            details.append(reason)
        }
        if let uid = entry.ownerUID {
            details.append("owner \(owner(name: entry.ownerName, uid: uid))")
        }
        if entry.isTrustedByConsent {
            details.append("trusted by you")
        }
        if let version = entry.version {
            details.append("gh \(version)")
        }
        if let error = entry.versionError {
            details.append("version check failed: \(error)")
        }
        if !details.isEmpty {
            text += " (\(details.joined(separator: listSeparator)))"
        }
        if entry.isChosen {
            text += " [chosen]"
        }
        return text
    }

    private static func accounts(_ model: GHDiagnosticsModel) -> [String] {
        guard model.accountsChecked else {
            return ["Accounts: not checked (no usable gh)"]
        }
        if let error = model.accountsError {
            return ["Accounts: gh auth status failed (\(error))"]
        }
        var lines = ["Accounts (github.com): \(model.accounts.isEmpty ? none : String(model.accounts.count))"]
        lines += model.accounts.map { account in
            var details = ["state \(account.state)"]
            if account.isActive {
                details.append("active")
            }
            details.append("token source \(account.tokenSource ?? none)")
            let scopes = account.missingScopes.isEmpty
                ? account.scopes
                : "\(account.scopes) (\(account.missingScopes.joined(separator: listSeparator)))"
            details.append("scopes \(scopes)")
            return "\(otherMarker) \(account.login): \(details.joined(separator: listSeparator))"
        }
        if !model.unusableAccounts.isEmpty {
            lines.append("Accounts FX Vault cannot use:")
            lines += model.unusableAccounts.map {
                "\(otherMarker) \($0.login): \($0.reason)\($0.isActive ? listSeparator + "active" : "")"
            }
        }
        return lines
    }
}
