import Foundation
import os
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// File secrets in the app (1.0 F1; boards Place-FileSheet, Place-FileDrop, Place-Table): the
/// Add file secret sheet over real files in a temporary folder, the drop on a place, and the label
/// in the table and the notes. File contents are synthetic.
@MainActor
@Suite("File secrets in the app")
struct FileSecretTests {
    /// Six lines and one trailing line break.
    static let keyText = "-----BEGIN FIXTURE-----\n" + ["FXV1", "FXV2", "FXV3", "FXV4"].joined(separator: "\n") + "\n-----END FIXTURE-----\n"
    static let label = FileSecretModel(fileName: "AuthKey_ABC123.p8", lineCount: 6, encoding: .text)

    /// A folder of its own under the temporary directory; removed by ``remove()``.
    struct Files {
        let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("fxv-file-secret-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func write(_ name: String, _ text: String) throws -> URL {
            try write(name, bytes: Data(text.utf8))
        }

        func write(_ name: String, bytes: Data) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func sheet(_ harness: TestHarness, place: ItemPlaceModel, file: URL? = nil) async -> FileSecretViewModel {
        let model = unloadedSheet(harness, place: place, file: file)
        await model.load()
        return model
    }

    private func unloadedSheet(
        _ harness: TestHarness,
        place: ItemPlaceModel,
        file: URL? = nil,
        readFile: @escaping @Sendable (URL) async -> Result<SecretBytes, SecretFileReader.ReadError> = FileSecretViewModel.readInBackground
    ) -> FileSecretViewModel {
        FileSecretViewModel(
            context: FileSecretContext(place: place, fileURL: file),
            dependencies: harness.dependencies(recorder: ActionRecorder()),
            readFile: readFile
        )
    }

    // MARK: - The sheet

    @Test func aDroppedKeyFileIsAddedAsExactTextWithItsLabel() async throws {
        let files = try Files()
        defer { files.remove() }
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let url = try files.write("AuthKey_ABC123.p8", Self.keyText)
        let model = await sheet(harness, place: .scope(repositoryID: id, scope: .repository), file: url)

        #expect(model.names.name == "AUTH_KEY_P8")
        let file = try #require(model.file)
        #expect(file.name == "AuthKey_ABC123.p8")
        #expect(FileSecretCopy.fileFacts(file.facts) == "· 66 bytes · 6 lines")
        #expect(model.storedEncoding == .text && model.isEncodingEditable)
        #expect(model.encodingHint == FileSecretCopy.base64Hint)
        #expect(model.removesTrailingLineBreaks)
        #expect(model.limitsLine == "GitHub 48,000 bytes · Key Vault 25,600 · this file 66 bytes (88 as Base64)")
        #expect(model.fileNote == nil)
        #expect(model.canSave)

        #expect(model.save())
        #expect(model.file == nil, "the bytes are dropped after the save")
        let item = try await EditorFixtures.item(harness, id, named: "AUTH_KEY_P8")
        #expect(item.kind == .secret)
        #expect(item.file == Self.label)
        #expect(try EditorFixtures.revealed(harness, item.id) == String(Self.keyText.dropLast()))
    }

    @Test func base64KeepsEveryByteAndABinaryFileHasNoChoice() async throws {
        let files = try Files()
        defer { files.remove() }
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let place = ItemPlaceModel.scope(repositoryID: id, scope: .repository)

        let text = await sheet(harness, place: place, file: try files.write("service-account.json", Self.keyText))
        text.encoding = .base64
        #expect(!text.removesTrailingLineBreaks)
        #expect(text.save())
        let json = try await EditorFixtures.item(harness, id, named: "SERVICE_ACCOUNT_JSON")
        #expect(try EditorFixtures.revealed(harness, json.id) == Data(Self.keyText.utf8).base64EncodedString())
        #expect(json.file == FileSecretModel(fileName: "service-account.json", lineCount: 6, encoding: .base64))

        let raw = Data([0x30, 0x82, 0x00, 0xFF, 0x0A])
        let binary = await sheet(harness, place: place, file: try files.write("cert.der", bytes: raw))
        #expect(!binary.isEncodingEditable)
        #expect(binary.storedEncoding == .base64, "Exact text is the default, but a binary file has none")
        #expect(binary.encodingHint == FileSecretCopy.binaryHint)
        #expect(binary.save())
        let der = try await EditorFixtures.item(harness, id, named: "CERT_DER")
        #expect(try EditorFixtures.revealed(harness, der.id) == raw.base64EncodedString())
        #expect(der.file == FileSecretModel(fileName: "cert.der", lineCount: nil, encoding: .base64))
    }

    @Test func aTypedNameStaysWhenAnotherFileIsChosen() async throws {
        let files = try Files()
        defer { files.remove() }
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let model = await sheet(harness, place: .scope(repositoryID: id, scope: .repository))
        #expect(model.file == nil && !model.canSave)
        #expect(model.limitsLine == "GitHub 48,000 bytes · Key Vault 25,600")

        await model.choose(try files.write("AuthKey_ABC123.p8", Self.keyText))
        #expect(model.names.name == "AUTH_KEY_P8")
        await model.choose(try files.write("server.pem", Self.keyText))
        #expect(model.names.name == "SERVER_PEM", "an untouched suggestion follows the file")

        model.names.name = "apns_key"
        await model.choose(try files.write("other.pem", Self.keyText))
        #expect(model.names.name == "APNS_KEY")
        #expect(model.file?.name == "other.pem")

        // A name the place already uses blocks the save (New Secret's rules).
        model.names.name = "API_TOKEN"
        #expect(model.nameNote?.isError == true)
        #expect(!model.canSave)
    }

    @Test func unreadableEmptyAndOversizedFilesCannotBeAdded() async throws {
        let files = try Files()
        defer { files.remove() }
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let model = await sheet(harness, place: .scope(repositoryID: id, scope: .repository))

        await model.choose(files.folder.appendingPathComponent("missing.p8"))
        #expect(model.readError == .unreadable)
        #expect(model.fileNote == .error(FileSecretCopy.readError(.unreadable, limit: Limits.maxValueBytes)))
        await model.choose(files.folder)
        #expect(model.readError == .notAFile)

        await model.choose(try files.write("empty.pem", "\n\n"))
        #expect(model.readError == nil)
        #expect(model.fileNote == .error(FileSecretCopy.empty), "only line breaks: nothing left as Exact text")
        #expect(!model.canSave)

        let huge = Limits.maxFileSecretReadBytes + 1
        await model.choose(try files.write("huge.json", String(repeating: "a", count: huge)))
        #expect(model.readError == .tooLarge(byteCount: huge))
        #expect(model.file == nil)

        // Just over GitHub's limit once in Base64.
        let text = String(repeating: "a", count: 36_001)
        await model.choose(try files.write("big.json", text))
        #expect(model.fileNote == nil)
        model.encoding = .base64
        let expected = FileSecretCopy.tooLarge(stored: 48_004, limit: Limits.maxValueBytes, encoding: .base64)
        #expect(model.fileNote == .error(expected))
        #expect(expected == "Stored as Base64, this file is 48,004 bytes. This place holds up to 48,000 bytes.")
        #expect(!model.canSave)
    }

    @Test func aKeyVaultTakesItsOwnLimitAndNames() async throws {
        let files = try Files()
        defer { files.remove() }
        let fixture = try await DestinationViewModelTests.Fixture()
        let vault = try fixture.addVault()
        let model = await sheet(fixture.harness, place: .destination(vault), file: try files.write("big.json", String(repeating: "a", count: 20_000)))
        #expect(model.fileNote == nil, "20,000 bytes of text fit Key Vault's 25,600")
        model.encoding = .base64
        #expect(model.fileNote == .error(FileSecretCopy.tooLarge(stored: 26_668, limit: Limits.maxKeyVaultValueBytes, encoding: .base64)))

        // Too large to read: the message gives Key Vault's own limit.
        await model.choose(try files.write("huge.json", String(repeating: "a", count: Limits.maxFileSecretReadBytes + 1)))
        #expect(model.fileNote == .error("This file is 96,001 bytes. This place holds up to 25,600 bytes."))
        await model.choose(try files.write("big.json", String(repeating: "a", count: 20_000)))

        model.encoding = .text
        model.names.name = String(repeating: "K", count: DestinationRules.maxKeyVaultNameLength + 1)
        #expect(model.nameNote?.isError == true, "Key Vault names have at most 127 characters")
        #expect(!model.canSave)
        model.names.name = "BIG_JSON"
        #expect(model.canSave)
        #expect(model.save())
        let item = try #require(try fixture.destinations.items(destinationID: vault).first { $0.name == "BIG_JSON" })
        #expect(item.file == FileSecretModel(fileName: "big.json", lineCount: 1, encoding: .text))
    }

    /// The place loads before the dropped file is read: a lock or a closed sheet in between
    /// reads nothing, and Cancel during a read throws away what it read.
    @Test func aLockedOrClosedSheetReadsNoFile() async throws {
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let place = ItemPlaceModel.scope(repositoryID: id, scope: .repository)
        let key = URL(fileURLWithPath: "/tmp/AuthKey.p8")
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let text = Self.keyText
        let readFile: @Sendable (URL) async -> Result<SecretBytes, SecretFileReader.ReadError> = { _ in
            reads.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(100))
            return .success(SecretBytes(utf8: text))
        }

        let locked = unloadedSheet(harness, place: place, file: key, readFile: readFile)
        locked.vaultDidLock()
        await locked.load()
        let closed = unloadedSheet(harness, place: place, file: key, readFile: readFile)
        let task = Task { await closed.load() }
        task.cancel()
        await task.value
        #expect(reads.withLock { $0 } == 0)
        #expect(locked.file == nil && closed.file == nil)

        let cancelled = unloadedSheet(harness, place: place, readFile: readFile)
        let reading = Task { await cancelled.choose(key) }
        while !cancelled.isReading {
            await Task.yield()
        }
        #expect(!cancelled.canSave, "nothing to save while the file is read")
        cancelled.dropFile()
        await reading.value
        #expect(reads.withLock { $0 } == 1)
        #expect(cancelled.file == nil && !cancelled.isReading)
    }

    @Test func lockingWipesTheFile() async throws {
        let files = try Files()
        defer { files.remove() }
        let (harness, id) = try await EditorFixtures.stagedHarness()
        let model = await sheet(harness, place: .scope(repositoryID: id, scope: .repository), file: try files.write("AuthKey.p8", Self.keyText))
        #expect(model.file != nil)
        harness.app.lock(trigger: .manual)
        #expect(model.file == nil)
        #expect(!model.canSave)
    }

    // MARK: - Places

    @Test func aPlaceOpensTheSheetForKeyFilesOnly() async throws {
        let fixture = try await FolderViewModelTests.Fixture()
        let folder = fixture.folder
        folder.kind = .variable
        let key = URL(fileURLWithPath: "/tmp/AuthKey.p8")
        folder.dropFile(key)
        #expect(fixture.recorder.presented == [.fileSecret(FileSecretContext(place: .folder(fixture.folderID), fileURL: key))])
        #expect(folder.kind == .secret, "the new secret shows when the sheet closes")

        folder.dropFile(URL(fileURLWithPath: "/tmp/notes.txt"))
        #expect(fixture.recorder.presented.count == 1)
        #expect(folder.alert == ErrorPresentationModel(title: FileSecretCopy.notDroppableTitle, message: FileSecretCopy.notDroppableMessage))

        folder.addFileSecret(from: nil)
        #expect(fixture.recorder.presented.last == .fileSecret(FileSecretContext(place: .folder(fixture.folderID))))
        #expect(folder.maxValueBytes == Limits.maxValueBytes)
        #expect(FileSecretCopy.dropDetail(limit: folder.maxValueBytes) == ".p8, .pem, .json · up to 48,000 bytes")

        let destinations = try await DestinationViewModelTests.Fixture()
        let vault = try destinations.detail(try destinations.addVault())
        #expect(vault.maxValueBytes == Limits.maxKeyVaultValueBytes)
        #expect(FileSecretCopy.dropDetail(limit: vault.maxValueBytes) == ".p8, .pem, .json · up to 25,600 bytes")
    }

    @Test func theTableAndTheNotesShowTheFileInPlaceOfTheMask() async throws {
        let fixture = try await FolderViewModelTests.Fixture()
        try fixture.harness.data.folders.addItem(
            folderID: fixture.folderID, kind: .secret, name: "APNS_KEY",
            value: SecretBytes(utf8: Self.keyText), file: Self.label
        )
        #expect(await fixture.waitForFolderRows(["FIREBASE_API_KEY", "APNS_KEY"]))
        let row = try #require(fixture.folder.rows.first { $0.name == "APNS_KEY" })
        #expect(row.file == Self.label)
        #expect(fixture.folder.rows.first { $0.name == "FIREBASE_API_KEY" }?.file == nil)
        let line = try #require(fixture.folder.notes.items.first { $0.name == "APNS_KEY" })
        #expect(line.file == Self.label)

        #expect(FileSecretCopy.tableLabel(Self.label) == "AuthKey_ABC123.p8 · 6 lines")
        #expect(FileSecretCopy.notesLabel(Self.label) == "AuthKey_ABC123.p8 · file · 6 lines")
        #expect(FileSecretCopy.accessibilityLabel(Self.label) == "From the file AuthKey_ABC123.p8, 6 lines")
        let binary = FileSecretModel(fileName: "cert.der", lineCount: nil, encoding: .base64)
        #expect(FileSecretCopy.tableLabel(binary) == "cert.der · Base64")
        #expect(FileSecretCopy.notesLabel(FileSecretModel(fileName: "a.pem", lineCount: 1, encoding: .base64)) == "a.pem · file · 1 line · Base64")
    }
}
