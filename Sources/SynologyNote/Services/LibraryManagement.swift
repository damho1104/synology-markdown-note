import Foundation
import AppKit
import NoteCore
import CryptoKit

/// Persist before sending create. The official API offers no proven idempotency
/// token: a lost response with no ID requires manual NAS reconciliation.
actor NotebookCreationManager {
    private struct Pending: Codable { var name: String; var objectID: String? }
    private let journalURL: URL
    private let retainReceipt: Bool
    init(directory: URL, retainReceipt: Bool = false) throws {
        self.retainReceipt = retainReceipt
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journalURL = directory.appendingPathComponent("notebook-create-pending.json")
    }

    func migrationDestination(name: String, client: NoteStationClient) async throws -> RemoteNotebook {
        if let pending = try readReceipt() {
            return try await confirmReceipt(pending, client: client)
        }
        let candidates = try await client.notebooks().filter { $0.name == name }
        if candidates.count == 1 {
            let book = candidates[0]
            // Persist the destination before moving any notes, including when
            // this migration reuses a notebook that was already on the NAS.
            let receipt = Pending(name: book.name, objectID: book.id)
            try JSONEncoder().encode(receipt).write(to: journalURL, options: .withoutOverwriting)
            return book
        }
        return try await create(name: name, client: client)
    }

    private func readReceipt() throws -> Pending? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        return try JSONDecoder().decode(Pending.self, from: Data(contentsOf: journalURL))
    }

    private func confirmReceipt(_ pending: Pending, client: NoteStationClient) async throws -> RemoteNotebook {
        guard let id = pending.objectID else { throw NoteStationError.notebookWriteUncertain(objectID: nil) }
        guard let confirmed = try await client.notebooks().first(where: { $0.id == id && $0.name == pending.name }) else {
            throw NoteStationError.notebookWriteUncertain(objectID: id)
        }
        if !retainReceipt { try FileManager.default.removeItem(at: journalURL) }
        return confirmed
    }

    func create(name: String, client: NoteStationClient) async throws -> RemoteNotebook {
        guard client.capabilities.supportsWrites else { throw NoteStationError.writeContractUnvalidated }
        guard await client.isAuthenticated else { throw NoteStationError.notConnected }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NoteStationError.invalidArgument("name") }
        if let pending = try readReceipt() {
            guard pending.name == name else {
                throw NoteStationError.notebookWriteUncertain(objectID: pending.objectID)
            }
            return try await confirmReceipt(pending, client: client)
        }
        // Exclusive creation also protects separate manager instances in the
        // same workspace. A partial journal fails closed after a crash.
        try JSONEncoder().encode(Pending(name: name)).write(to: journalURL, options: .withoutOverwriting)
        do {
            let confirmed = try await client.createNotebook(name: name)
            // Persist the acknowledged identity before clearing the journal.
            try JSONEncoder().encode(Pending(name: name, objectID: confirmed.id)).write(to: journalURL, options: .atomic)
            if !retainReceipt { try FileManager.default.removeItem(at: journalURL) }
            return confirmed
        } catch {
            if case NoteStationError.notebookWriteUncertain(let id) = error {
                if let id { try JSONEncoder().encode(Pending(name: name, objectID: id)).write(to: journalURL, options: .atomic) }
            } else if let failure = error as? NoteStationError {
                switch failure {
                case .invalidArgument, .writeContractUnvalidated, .notConnected, .unsupportedAPI, .permissionDenied, .sessionExpired, .api:
                    try FileManager.default.removeItem(at: journalURL)
                default: break
                }
            }
            throw error
        }
    }
}

extension LibraryStore {
    var canManageNASNotebooks: Bool { isConnected && client?.capabilities.supportsWrites == true }

    /// Persist a per-installation probe name before any NAS request. Separate Macs
    /// must not collide even when connected to the same NAS account.
    func validationNotebookName() async throws -> String {
        let directory = root.appendingPathComponent(profile.storageKey)
            .appendingPathComponent("nas-validation-notebook")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nameURL = directory.appendingPathComponent("probe-name.txt")
        if !FileManager.default.fileExists(atPath: nameURL.path) {
            // A missing name beside a write journal could belong to an already
            // submitted create. Never generate a second identity in that case.
            let pendingURL = directory.appendingPathComponent("notebook-create-pending.json")
            guard !FileManager.default.fileExists(atPath: pendingURL.path) else {
                throw NoteStationError.notebookWriteUncertain(objectID: nil)
            }
            let name = "SynologyNote 검사 \(UUID().uuidString.lowercased().prefix(12))"
            do { try Data(name.utf8).write(to: nameURL, options: .withoutOverwriting) }
            catch {
                guard FileManager.default.fileExists(atPath: nameURL.path) else { throw error }
            }
        }
        let saved = try String(contentsOf: nameURL, encoding: .utf8)
        guard saved.hasPrefix("SynologyNote 검사 "), saved.count > "SynologyNote 검사 ".count else {
            throw NoteStationError.invalidArgument("validationNotebookName")
        }
        return saved
    }

    func ensureNASValidationNotebook() async throws -> Notebook {
        guard let client, isConnected, client.capabilities.supportsWrites else {
            throw NoteStationError.notConnected
        }
        let generation = accountGeneration, connection = connectionGeneration, repo = repository
        let name = try await validationNotebookName()
        let directory = root.appendingPathComponent(profile.storageKey)
            .appendingPathComponent("nas-validation-notebook")
        let manager = try NotebookCreationManager(directory: directory, retainReceipt: true)
        let remote = try await manager.create(name: name, client: client)
        guard generation == accountGeneration, connection == connectionGeneration,
              self.client === client, isConnected else { throw NoteStationError.connectionChanged }
        let notebook = Notebook(id: remote.id, name: remote.name)
        var books = try await repo.notebooks()
        guard generation == accountGeneration, connection == connectionGeneration,
              self.client === client, isConnected else { throw NoteStationError.connectionChanged }
        books.removeAll { $0.id == notebook.id }
        books.append(notebook)
        try await repo.setNotebooks(books)
        guard generation == accountGeneration, connection == connectionGeneration,
              self.client === client, isConnected else { throw NoteStationError.connectionChanged }
        try await reload()
        return notebook
    }

    @discardableResult
    func createNotebook(named name: String) async throws -> Notebook {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NoteStationError.invalidArgument("name") }
        let generation = accountGeneration, repo = repository
        guard let client, canManageNASNotebooks else { throw NoteStationError.notConnected }
        let directory = root.appendingPathComponent(profile.storageKey)
        let manager = try NotebookCreationManager(directory: directory)
        let remote = try await manager.create(name: name, client: client)
        guard generation == accountGeneration, self.client === client else { throw NoteStationError.connectionChanged }
        let book = Notebook(id: remote.id, name: remote.name)
        var books = try await repo.notebooks()
        guard generation == accountGeneration else { throw NoteStationError.connectionChanged }
        books.removeAll { $0.id == book.id }; books.append(book)
        try await repo.setNotebooks(books)
        guard generation == accountGeneration else { throw NoteStationError.connectionChanged }
        try await reload()
        logEvent(.notebookCreated, notebookID: book.id)
        return book
    }

    func renameNotebook(id: String, name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NoteStationError.invalidArgument("name") }
        let generation = accountGeneration, repo = repository
        var books = try await repo.notebooks()
        guard generation == accountGeneration else { throw NoteStationError.connectionChanged }
        guard books.contains(where: { $0.id == id }) else { throw NoteStationError.invalidArgument("notebookID") }
        guard isNASNotebook(id) else { throw RepositoryError(message: appText("Sync the notebook to the NAS before renaming it.")) }
        do {
            guard let client, canManageNASNotebooks else { throw NoteStationError.writeContractUnvalidated }
            let remote = try await client.renameNotebook(notebookID: id, name: name)
            guard generation == accountGeneration, self.client === client else { throw NoteStationError.connectionChanged }
            // Re-read so unrelated notebook changes made during the await survive.
            books = try await repo.notebooks()
            guard generation == accountGeneration else { throw NoteStationError.connectionChanged }
            guard let current = books.firstIndex(where: { $0.id == id }) else { throw NoteStationError.invalidArgument("notebookID") }
            books[current].name = remote.name
        }
        try await repo.setNotebooks(books)
        guard generation == accountGeneration else { throw NoteStationError.connectionChanged }
        try await reload()
        logEvent(.notebookRenamed, notebookID: id)
    }

    func promptRenameNotebook(_ book: Notebook) {
        let generation = accountGeneration
        let alert = NSAlert()
        alert.messageText = appText("Rename Notebook")
        alert.informativeText = appText("Change the notebook’s name on the NAS.")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = book.name; alert.accessoryView = input
        alert.addButton(withTitle: appText("Rename")); alert.addButton(withTitle: appText("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            guard generation == accountGeneration else { return }
            do { try await renameNotebook(id: book.id, name: input.stringValue) } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeAttachment(_ attachment: NoteAttachment, from session: EditorSession) async {
        guard session.workspaceGeneration == accountGeneration, sessions[session.id] === session else { return }
        let generation = accountGeneration
        let store = attachments
        do {
            // The source envelope is protocol metadata, not a user attachment.
            let data = try await store.verifiedData(for: attachment)
            guard generation == accountGeneration, session.workspaceGeneration == generation else { return }
            if let source = try? SourceEnvelope.decode(data), source.documentID == (session.note.sourceDocumentID ?? session.id) {
                throw RepositoryError(message: appText("The Markdown recovery source is managed automatically and cannot be removed directly."))
            }
            _ = try AttachmentManagement.removing(attachment, from: session.note)
            // Save the pre-removal edit first so even an unsaved new attachment
            // remains recoverable in local history.
            await save(session)
            guard generation == accountGeneration, session.workspaceGeneration == generation, session.saveError == nil else { return }
            // Re-evaluate current references if another edit occurred while saving.
            let current = try AttachmentManagement.removing(attachment, from: session.note)
            edit(session, registerUndo: true) { $0.attachments = current.attachments }
            await save(session)
        } catch { if generation == accountGeneration { errorMessage = error.localizedDescription } }
    }
}
