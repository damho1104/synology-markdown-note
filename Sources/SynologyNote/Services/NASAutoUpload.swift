import Foundation
import NoteCore

struct AutomaticUploadValidation: Codable {
    var checkedAt = Date()
    var remoteID: String?
    var createVerified = false
    var updateVerified = false
    var lostResponseRecovered = false
    var failure: String?
    var passed: Bool { createVerified && updateVerified && lostResponseRecovered && failure == nil }
}

extension LibraryStore {
    func isNASNotebook(_ id: String) -> Bool { !profile.server.isEmpty && id != "local" && !id.hasPrefix("local-") }
    func lastAutomaticUploadValidation() -> AutomaticUploadValidation? {
        try? JSONDecoder().decode(AutomaticUploadValidation.self, from: Data(contentsOf: root.appendingPathComponent(profile.storageKey).appendingPathComponent("nas-auto-upload-validation.json")))
    }
    var automaticUploadReady: Bool { isConnected && client?.capabilities.supportsWrites == true }
    func configureUploads() throws {
        guard let client, client.capabilities.supportsWrites else { syncCoordinator = nil; return }
        let transport = try NoteStationSyncTransport(client: client, repository: repository, assets: attachments,
            directory: root.appendingPathComponent(profile.storageKey).appendingPathComponent("upload-journal"))
        uploadTransport = transport
        let account = String(profile.storageKey.prefix(12))
        syncCoordinator = SyncCoordinator(repository: repository, attachments: attachments, transport: transport, mathRenderer: MathImageRenderer(),
            reportError: { [weak self] noteID, error in
                await self?.logEvent(.uploadFailed, noteID: noteID, fields: ["account": account], error: error)
            })
    }
    func scheduleUpload() {
        guard automaticUploadReady else { return }
        if isPushing { uploadAgain = true; return }
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            await self?.pushPendingUploads()
        }
    }
    func startUploadLoop() {
        uploadLoop?.cancel()
        guard automaticUploadReady else { return }
        uploadLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await self?.pushPendingUploads()
            }
        }
    }
    func pushPendingUploads() async {
        guard let coordinator = syncCoordinator, isConnected, !isPushing, !isRefreshing, !isManagingStacks, deletingNotebookIDs.isEmpty, deletingNoteIDs.isEmpty,
              automaticUploadReady else { return }
        let generation = connectionGeneration, account = accountGeneration, repo = repository
        isPushing = true; uploadAgain = false; uploadStatus = "NAS에 전송 중…"
        defer {
            if generation == connectionGeneration {
                isPushing = false
                if uploadAgain { scheduleUpload() }
            }
        }
        await flush()
        guard generation == connectionGeneration, account == accountGeneration else { return }
        do {
            let queued = try await repo.pendingOperations()
            if !queued.isEmpty { logEvent(.uploadStarted, fields: ["count": String(queued.count)]) }
            try await migrateLegacyNotebooks()
            guard generation == connectionGeneration, account == accountGeneration else { return }
            var eligible: Set<UUID> = []
            for operation in try await repo.pendingOperations() {
                if let note = try await repo.note(id: operation.noteID), isNASNotebook(note.notebookID) { eligible.insert(note.id) }
            }
            await coordinator.push(noteIDs: eligible)
            guard generation == connectionGeneration, account == accountGeneration else { return }
            for session in Array(sessions.values) {
                let editing = session.editGeneration, saving = session.savedGeneration
                guard let saved = try await repo.note(id: session.id) else { continue }
                guard generation == connectionGeneration else { return }
                integrateUploadedRecord(saved, into: session, expectedEditGeneration: editing, expectedSavedGeneration: saving)
            }
            try await reload()
            let pending = try await repo.pendingOperations().filter { eligible.contains($0.noteID) }
            if !eligible.isEmpty { logEvent(.uploadCompleted, fields: ["count": String(eligible.count), "pending": String(pending.count)]) }
            for operation in pending {
                logEvent(.uploadPending, noteID: operation.noteID, fields: ["state": operation.state.rawValue, "attempts": String(operation.attempts)])
            }
            uploadStatus = pending.isEmpty ? "NAS 동기화 완료" : pending.contains(where: { $0.state == .conflict || $0.state == .uncertain }) ? "일부 변경 확인 필요" : "\(pending.count)개 전송 대기"
            if let client, !(await client.isAuthenticated) { requestConnectionRecovery(after: NoteStationError.sessionExpired) }
            else { startOfflineDownload() }
        } catch {
            uploadStatus = "NAS 전송 확인 필요"; connectionError = error.localizedDescription
            logEvent(.uploadFailed, error: error)
        }
    }

    func integrateUploadedRecord(_ saved: NoteRecord, into session: EditorSession, expectedEditGeneration: Int, expectedSavedGeneration: Int) {
        guard saved.revision >= session.note.revision else { return }
        if session.editGeneration == expectedEditGeneration && session.savedGeneration == expectedSavedGeneration
            && session.editGeneration == session.savedGeneration { session.note = saved }
        else {
            let hasHTMLDraft = session.note.mode == .original && session.editGeneration != session.savedGeneration
            session.note.remoteID = saved.remoteID; session.note.serverVersion = saved.serverVersion
            session.note.sourceDocumentID = saved.sourceDocumentID; session.note.baseHTML = saved.baseHTML
            if !hasHTMLDraft { session.note.originalHTML = saved.originalHTML }
            session.note.listedVersion = saved.listedVersion
            session.note.syncState = saved.syncState; session.note.lastError = saved.lastError
            session.note.conflictHTML = saved.conflictHTML; session.note.conflictVersion = saved.conflictVersion; session.note.conflictSnapshot = saved.conflictSnapshot
            for index in session.note.attachments.indices {
                if let remote = saved.attachments.first(where: { $0.id == session.note.attachments[index].id }) {
                    session.note.attachments[index].remoteID = remote.remoteID; session.note.attachments[index].remoteReference = remote.remoteReference
                }
            }
    }
    }
    func resolveSyncAttempt(for session: EditorSession) async throws {
        for attempt in try await repository.syncAttempts() where attempt.note.id == session.id {
            guard session.note.remoteID != nil else { throw SyncError.uncertain }
            try await repository.discardAttempt(noteID: session.id)
            await uploadTransport?.finish(operationID: attempt.operation.id)
        }
    }

    /// Optional diagnostics on an isolated synthetic repository. Normal uploads
    /// never depend on these diagnostic reports.
    func validateAutomaticUpload(notebookID: String) async throws -> AutomaticUploadValidation {
        guard let client, isConnected, client.capabilities.supportsWrites, isNASNotebook(notebookID) else { throw NoteStationError.writeContractUnvalidated }
        let generation = connectionGeneration
        var report = AutomaticUploadValidation()
        let directory = root.appendingPathComponent(profile.storageKey).appendingPathComponent("sync-probes").appendingPathComponent(UUID().uuidString)
        let repo = try NoteRepository(directory: directory), assets = try AttachmentStore(directory: directory.appendingPathComponent("assets"))
        let transport = try NoteStationSyncTransport(client: client, repository: repo, assets: assets, directory: directory.appendingPathComponent("journal"))
        let loss = ConfirmationLossTransport(base: transport)
        let coordinator = SyncCoordinator(repository: repo, attachments: assets, transport: loss)
        do {
            let image = try await assets.importData(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQzrvzH4QZYAwAUT4JsSqASqYAAAAASUVORK5CYII=")!, name: "검증 이미지.png")
            let file = try await assets.importData(Data("SynologyNote automatic upload probe\n".utf8), name: "검증 파일.txt")
            var note = NoteRecord(title: "[SynologyNote 검증] 자동 업로드 \(UUID().uuidString.lowercased())", notebookID: notebookID,
                                  markdown: "# 자동 업로드 검증\n\n![이미지](\(image.reference))\n\n[파일](\(file.reference))\n")
            note.attachments = [image, file]
            note = try await repo.save(note)
            await coordinator.push()
            guard try await repo.syncAttempts().count == 1 else { throw SyncError.verificationFailed }
            await coordinator.push()
            note = try await repo.note(id: note.id)!
            report.remoteID = note.remoteID
            guard note.syncState == .synced else { throw RepositoryError(message: note.lastError ?? "생성 확인 실패") }
            report.createVerified = true
            report.lostResponseRecovered = await loss.writeCount == 1
            note.markdown += "\n수정 저장 확인\n"; note.tags = ["SynologyNote 검증"]; note.isFavorite = true
            note = try await repo.save(note)
            await coordinator.push()
            note = try await repo.note(id: note.id)!
            guard note.syncState == .synced else { throw RepositoryError(message: note.lastError ?? "수정 확인 실패") }
            note.isFavorite = false
            note = try await repo.save(note); await coordinator.push()
            note = try await repo.note(id: note.id)!
            guard note.syncState == .synced else { throw RepositoryError(message: note.lastError ?? "즐겨찾기 복원 확인 실패") }
            report.updateVerified = true
        } catch { report.failure = error.localizedDescription }
        guard generation == connectionGeneration else { throw NoteStationError.connectionChanged }
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent(profile.storageKey).appendingPathComponent("nas-auto-upload-validation.json"), options: .atomic)
        await refreshFromServer()
        return report
    }
}

private actor ConfirmationLossTransport: SyncTransport {
    let base: NoteStationSyncTransport
    var writeCount = 0
    init(base: NoteStationSyncTransport) { self.base = base }
    func fetch(remoteID: String) async throws -> SyncRemoteSnapshot { try await base.fetch(remoteID: remoteID) }
    func write(_ payload: SyncWritePayload) async throws -> SyncRemoteSnapshot {
        writeCount += 1
        let result = try await base.write(payload)
        if writeCount == 1 { throw URLError(.networkConnectionLost) }
        return result
    }
    func reconcile(_ attempt: SyncAttempt) async throws -> SyncReconciliation { try await base.reconcile(attempt) }
    func finish(operationID: UUID) async { await base.finish(operationID: operationID) }
}
