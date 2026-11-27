import Foundation
import AppKit
import CryptoKit
import NoteCore

extension LibraryStore {
    /// Upgrade notebooks created by old builds inside this NAS account only.
    /// Keep the acknowledged server identity on disk until every note is moved.
    func migrateLegacyNotebooks() async throws {
        guard let client, isConnected else { throw NoteStationError.notConnected }
        let generation = accountGeneration, connection = connectionGeneration, repo = repository
        let directory = root.appendingPathComponent(profile.storageKey).appendingPathComponent("notebook-migration")
        var oldBooks = try await repo.notebooks().filter { !isNASNotebook($0.id) }
        for row in try await repo.listNotes() where !isNASNotebook(row.notebookID) && !oldBooks.contains(where: { $0.id == row.notebookID }) {
            oldBooks.append(Notebook(id: row.notebookID, name: appText("My Notebook")))
        }
        for oldBook in oldBooks {
            logEvent(.notebookMigrating, notebookID: oldBook.id)
            let name = oldBook.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? appText("My Notebook") : oldBook.name
            let key = SHA256.hash(data: Data(oldBook.id.utf8)).map { String(format: "%02x", $0) }.joined()
            let manager = try NotebookCreationManager(directory: directory.appendingPathComponent(key), retainReceipt: true)
            let remote = try await manager.migrationDestination(name: name, client: client)
            guard generation == accountGeneration, connection == connectionGeneration, self.client === client else { throw NoteStationError.connectionChanged }
            for row in try await repo.listNotes() where row.notebookID == oldBook.id {
                guard generation == accountGeneration, connection == connectionGeneration else { throw NoteStationError.connectionChanged }
                if let session = sessions[row.id] {
                    if session.note.notebookID == oldBook.id { edit(session) { $0.notebookID = remote.id } }
                    await save(session)
                    if let error = session.saveError { throw RepositoryError(message: error) }
                } else if var note = try await repo.note(id: row.id), note.notebookID == oldBook.id {
                    note.notebookID = remote.id
                    _ = try await repo.save(note)
                }
            }
            guard generation == accountGeneration, connection == connectionGeneration else { throw NoteStationError.connectionChanged }
            var books = try await repo.notebooks()
            books.removeAll { $0.id == oldBook.id || $0.id == remote.id }
            books.append(Notebook(id: remote.id, name: remote.name))
            try await repo.setNotebooks(books)
            logEvent(.notebookMigrated, notebookID: remote.id)
        }
        try await reload()
    }

    func deleteNotebook(id: String) async throws {
        guard let client, canManageNASNotebooks, isNASNotebook(id) else { throw NoteStationError.notConnected }
        guard !isPushing, !isRefreshing, !isManagingStacks, !deletingNotebookIDs.contains(id) else {
            throw RepositoryError(message: appText("Wait for sync to finish before deleting the notebook."))
        }
        let generation = accountGeneration, connection = connectionGeneration, repo = repository
        logEvent(.notebookDeleteRequested, notebookID: id)
        var confirmed = false
        defer { if !confirmed { logEvent(.notebookDeleteFailed, notebookID: id) } }
        deletingNotebookIDs.insert(id)
        defer { deletingNotebookIDs.remove(id); scheduleUpload() }
        await flush()
        guard generation == accountGeneration, connection == connectionGeneration, self.client === client else { throw NoteStationError.connectionChanged }
        let pendingIDs = Set(try await repo.pendingOperations().map(\.noteID))
        guard try await repo.listNotes().allSatisfy({ $0.notebookID != id || !pendingIDs.contains($0.id) }),
              !sessions.values.contains(where: { $0.note.notebookID == id && $0.saveError != nil }) else {
            throw RepositoryError(message: appText("This notebook has changes waiting to upload. Finish syncing before deleting it."))
        }
        guard generation == accountGeneration, connection == connectionGeneration, self.client === client else { throw NoteStationError.connectionChanged }
        try await client.deleteNotebook(notebookID: id)
        guard generation == accountGeneration, connection == connectionGeneration, self.client === client else { throw NoteStationError.connectionChanged }
        for row in try await repo.listNotes() where row.notebookID == id {
            guard var note = try await repo.note(id: row.id) else { continue }
            note.isTrashed = true
            note.syncState = .synced
            let saved = try await repo.save(note, enqueue: false)
            if let session = sessions[row.id] { session.note = saved }
        }
        var books = try await repo.notebooks()
        books.removeAll { $0.id == id }
        try await repo.setNotebooks(books)
        confirmed = true
        logEvent(.notebookDeleted, notebookID: id)
        try await reload()
        deletingNotebookIDs.remove(id)
        await refreshFromServer()
    }

    func promptDeleteNotebook(_ book: Notebook) {
        let generation = accountGeneration
        let alert = NSAlert()
        alert.messageText = appText("Delete the “%@” notebook?", "\(book.name.isEmpty ? appText("Untitled Notebook") : book.name)")
        alert.informativeText = appText("This deletes the notebook from the NAS and moves its notes to the Trash. Pending changes block deletion.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: appText("Delete"))
        alert.addButton(withTitle: appText("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            guard generation == accountGeneration else { return }
            do { try await deleteNotebook(id: book.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
