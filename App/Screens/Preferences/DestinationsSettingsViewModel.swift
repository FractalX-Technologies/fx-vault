import DestinationKit
import Foundation
import Observation
import VaultCore
import VaultData

/// Preferences › Destinations (v0.8.0, tasks/todo.md R4): whether the Azure CLI is signed in,
/// and the Supabase and Vercel tokens FX Vault keeps (sealed in the vault): add (checked with the
/// provider first), rename, replace and remove.
///
/// A typed token lives only in ``ConnectionEditorModel/token`` while its sheet is open; it is
/// cleared after the save, on close and on lock, and never logged.
@Observable
final class DestinationsSettingsViewModel: LockObserving {
    enum AzureState: Equatable {
        case unknown
        case checking
        case signedIn
        case problem(String)
    }

    private(set) var connections: [ConnectionModel] = []
    private(set) var azureState: AzureState = .unknown
    /// The open add or replace sheet.
    var editor: ConnectionEditorModel?
    /// The connection waiting for the "Remove?" confirmation.
    var pendingRemoval: ConnectionModel?
    /// The connection being renamed, with the new name.
    var renaming: ConnectionModel?
    var renameText = ""
    var alert: ErrorPresentationModel?
    private(set) var notice: String?

    @ObservationIgnored private let app: AppViewModel
    @ObservationIgnored private let tasks = TaskBag()

    init(app: AppViewModel) {
        self.app = app
        app.addLockObserver(self)
        observe()
    }

    var isUnlocked: Bool {
        app.phase == .unlocked
    }

    private var destinations: DestinationRepository {
        app.container.data.destinations
    }

    private func observe() {
        let stream = destinations.observeConnections()
        tasks.set("connections", Task { [weak self] in
            do {
                for try await connections in stream {
                    self?.connections = connections
                }
            } catch {
                AppLog.ui.error("Connection observation ended")
            }
        })
    }

    // MARK: - Azure CLI

    /// Asks `az` for a Key Vault token (nothing is stored).
    func checkAzure() {
        azureState = .checking
        let access = app.container.data.destinationAccess
        tasks.set("azure", Task { [weak self] in
            do throws(DestinationError) {
                try await access.checkAzure(tenantID: nil)
                self?.azureState = .signedIn
            } catch {
                self?.azureState = .problem(error.localizedMessage(provider: .azureKeyVault))
            }
        })
    }

    func copyAzLogin() {
        app.container.clipboard.copyCommand(DestinationSyncCopy.azLoginCommand)
        notice = String(localized: "settings.destinations.azCopied", defaultValue: "Copied az login. Run it in Terminal, then check again.")
    }

    // MARK: - Connections

    func addConnection() {
        editor = ConnectionEditorModel(mode: .add, provider: .vercel)
    }

    func replaceToken(of connection: ConnectionModel) {
        editor = ConnectionEditorModel(mode: .replace(connection.id), provider: connection.provider, label: connection.label)
    }

    /// Checks the editor's token with the provider, then saves it.
    func saveEditor() {
        guard let editor, editor.canSave else { return }
        let token = SecretBytes(utf8: editor.token)
        self.editor?.token = ""
        self.editor?.isChecking = true
        self.editor?.error = nil
        let access = app.container.data.destinationAccess
        let destinations = destinations
        tasks.set("save", Task { [weak self] in
            defer { token.wipe() }
            do throws(DestinationError) {
                let hint = try await access.check(token, provider: editor.provider)
                do {
                    switch editor.mode {
                    case .add:
                        try destinations.addConnection(provider: editor.provider, label: editor.label, token: token, accountHint: hint)
                    case .replace(let id):
                        try destinations.replaceToken(of: id, with: token, accountHint: hint)
                    }
                    self?.editor = nil
                } catch {
                    self?.editor?.isChecking = false
                    self?.alert = error.presentation
                }
            } catch {
                self?.editor?.isChecking = false
                self?.editor?.error = error.localizedMessage(provider: editor.provider)
            }
        })
    }

    func cancelEditor() {
        editor = nil
    }

    func startRename(_ connection: ConnectionModel) {
        renaming = connection
        renameText = connection.label
    }

    func confirmRename() {
        guard let renaming else { return }
        self.renaming = nil
        do {
            try destinations.renameConnection(renaming.id, to: renameText)
        } catch {
            alert = error.presentation
        }
    }

    func requestRemoval(_ connection: ConnectionModel) {
        pendingRemoval = connection
    }

    func confirmRemoval() {
        guard let connection = pendingRemoval else { return }
        pendingRemoval = nil
        do {
            try destinations.deleteConnection(connection.id)
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        editor = nil
        renaming = nil
        pendingRemoval = nil
        azureState = .unknown
    }
}

/// The add or replace token sheet.
struct ConnectionEditorModel: Identifiable, Equatable {
    enum Mode: Equatable {
        case add
        case replace(ConnectionID)
    }

    let mode: Mode
    var provider: DestinationProvider
    var label = ""
    var token = ""
    var isChecking = false
    var error: String?

    var id: String {
        switch mode {
        case .add: "add"
        case .replace(let id): id.uuidString
        }
    }

    var canSave: Bool {
        !token.isEmpty && !isChecking && (mode != .add || FolderNameValidator.isValid(label.trimmingCharacters(in: .whitespaces)))
    }
}
