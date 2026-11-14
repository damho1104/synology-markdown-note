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
              let version = session.note.serverVersion ?? session.note.listedVersion else { throw RepositoryError(message: "NAS 연결과 휴지통 동기화를 완료한 뒤 영구 삭제하세요.") }
        let generation = accountGeneration, connection = connectionGeneration, repo = repository, assets = attachments
        deletingNoteIDs.insert(session.id)
        cancelOfflineDownload()
        defer { deletingNoteIDs.remove(session.id); scheduleUpload() }
        logEvent(.noteDeleteRequested, noteID: session.id)
        do {
            await flush()
            guard session.editGeneration == session.savedGeneration,
                  try await !repo.pendingOperations().contains(where: { $0.noteID == session.id }),
                  try await !repo.syncAttempts().contains(where: { $0.note.id == session.id }) else { throw RepositoryError(message: "전송 대기 중인 변경을 먼저 확인하세요.") }
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
        guard canPermanentlyDelete(session.note) else { errorMessage = "NAS 연결과 휴지통 동기화를 완료한 뒤 영구 삭제하세요."; return }
        let generation = accountGeneration
        let alert = NSAlert()
        alert.messageText = "‘\(session.note.title)’ 노트를 영구 삭제할까요?"
        alert.informativeText = "NAS의 노트와 첨부, 이 Mac에 보관된 노트와 수정 이력을 삭제합니다. 다른 기기에서도 사라지며 복원할 수 없습니다."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "영구 삭제").keyEquivalent = ""
        alert.addButton(withTitle: "취소").keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            guard generation == accountGeneration else { return }
            do { try await permanentlyDelete(session) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
