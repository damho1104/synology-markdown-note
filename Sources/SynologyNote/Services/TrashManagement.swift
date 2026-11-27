import AppKit
import Foundation
import NoteCore

extension LibraryStore {
    func canPermanentlyDelete(_ note: NoteRecord) -> Bool {
        note.isTrashed && note.remoteID != nil && (note.serverVersion ?? note.listedVersion) != nil &&
            (note.syncState == .synced || note.syncState == .local) && isConnected &&
            !isPushing && !isRefreshing && deletingNoteIDs.isEmpty && deletingNotebookIDs.isEmpty
    }

    func permanentlyDelete(_ session: EditorSession) async throws {
        guard sessions[session.id] === session, session.workspaceGeneration == accountGeneration,
              canPermanentlyDelete(session.note), let client, let remoteID = session.note.remoteID,
              let version = session.note.serverVersion ?? session.note.listedVersion else { throw RepositoryError(message: appText("Connect to the NAS and sync the Trash before permanently deleting notes.")) }
        let generation = accountGeneration, connection = connectionGeneration, repo = repository, assets = attachments
        deletingNoteIDs.insert(session.id)
        cancelOfflineDownload()
        defer { deletingNoteIDs.remove(session.id); scheduleUpload() }
        logEvent(.noteDeleteRequested, noteID: session.id)
        do {
            await flush()
            guard session.editGeneration == session.savedGeneration,
                  try await !repo.pendingOperations().contains(where: { $0.noteID == session.id }),
                  try await !repo.syncAttempts().contains(where: { $0.note.id == session.id }) else { throw RepositoryError(message: appText("Review pending changes first.")) }
            guard generation == accountGeneration, connection == connectionGeneration else { throw NoteStationError.connectionChanged }
            try await client.permanentlyDeleteNote(noteID: remoteID, baseVersion: version)
            guard generation == accountGeneration, connection == connectionGeneration, self.client === client else { throw NoteStationError.connectionChanged }
            let unused = try await repo.purgeConfirmedTrash(noteID: session.id, remoteID: remoteID)
            session.saveTask?.cancel(); session.undoManager.removeAllActions()
            sessions.removeValue(forKey: session.id)
            for file in unused {
                do { try await assets.removeUnreferencedCache(file) }
                catch { logEvent(.noteDeleteCacheFailed, noteID: session.id, error: error) }
            }
            try await reload()
            logEvent(.noteDeleted, noteID: session.id)
        } catch {
            logEvent(.noteDeleteFailed, noteID: session.id, error: error)
            throw error
        }
    }

    func promptPermanentlyDelete(_ session: EditorSession) {
        guard canPermanentlyDelete(session.note) else { errorMessage = appText("Connect to the NAS and sync the Trash before permanently deleting notes."); return }
        let generation = accountGeneration
        let alert = NSAlert()
        alert.messageText = appText("Permanently delete “%@”?", "\(session.note.title)")
        alert.informativeText = appText("This deletes the note and attachments from the NAS and the local note and revision history from this Mac. It cannot be undone and affects other devices.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: appText("Delete Permanently")).keyEquivalent = ""
        alert.addButton(withTitle: appText("Cancel")).keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            guard generation == accountGeneration else { return }
            do { try await permanentlyDelete(session) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
