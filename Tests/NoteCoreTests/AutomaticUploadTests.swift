import Foundation
import Testing
@testable import NoteCore
@testable import SynologyNote

@Suite @MainActor struct AutomaticUploadTests {
    @Test func lateUploadRefreshCannotReplaceNewerSavedEditorRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile())
        var stale = NoteRecord(markdown: "old text"); stale.revision = 1
        var latest = stale; latest.revision = 2; latest.markdown = "new text already saved"
        let session = EditorSession(note: latest, workspaceGeneration: 0)
        session.editGeneration = 2; session.savedGeneration = 2
        store.integrateUploadedRecord(stale, into: session, expectedEditGeneration: 2, expectedSavedGeneration: 1)
        #expect(session.note.markdown == "new text already saved")
        #expect(session.note.revision == 2)
    }
    @Test func editingSchedulesUploadAndUpdatesOpenSessionAfterConfirmation() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        let store = try makeStore(f)
        defer { store.uploadLoop?.cancel(); store.uploadTask?.cancel() }
        let id = try #require(await store.newNote(notebookID: "book"))
        let session = try #require(await store.session(for: id))
        store.edit(session) { $0.markdown = "# 자동 저장된 변경" }
        // Await the scheduled work instead of racing CI's other MainActor tests
        // against an arbitrary six-second polling window. Do not push manually:
        // this test must still prove that editing schedules the upload itself.
        for _ in 0..<10 {
            await session.saveTask?.value
            await store.uploadTask?.value
            if session.note.syncState == .synced { break }
            // A save/upload can replace the task we just awaited. Follow the
            // newly scheduled task rather than treating the old task as idle.
            await Task.yield()
        }
        #expect(session.note.syncState == .synced)
        #expect(session.note.remoteID != nil)
        #expect(session.note.markdown == "# 자동 저장된 변경")
        #expect(f.server.counts().creates == 1)
        #expect(try await store.repository.pendingOperations().isEmpty)
        store.edit(session) { $0.markdown += "\n\n다시 편집한 내용" }
        await store.flush()
        for _ in 0..<10 {
            await store.uploadTask?.value
            if session.note.syncState == .synced { break }
            await Task.yield()
        }
        let remoteID = try #require(session.note.remoteID)
        let remote = try await f.client.fetch(noteID: remoteID)
        #expect(remote.html.contains("다시 편집한 내용"))
        #expect(session.note.syncState == .synced)
        #expect(f.server.counts().creates == 1)
    }

    @Test func freshInstallRequiresNASInsteadOfCreatingLocalWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile())
        await store.load()
        #expect(store.notebooks.isEmpty && store.summaries.isEmpty)
        #expect(!store.canCreateNotes)
        #expect(await store.newNote() == nil)
        #expect(try await store.repository.pendingOperations().isEmpty)
    }

    @Test func offlineNewNotesUseCachedNASNotebookAndQueueForReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://example.invalid", username: "user"))
        try await store.repository.setNotebooks([Notebook(id: "local-old", name: "old"), Notebook(id: "nas-book", name: "NAS")])
        await store.load()
        let id = try #require(await store.newNote())
        #expect(try await store.repository.note(id: id)?.notebookID == "nas-book")
        #expect(try await store.repository.note(id: id)?.syncState == .pending)
        #expect(!store.isConnected)
    }

    @Test func legacyDisabledPreferenceCannotPreventPendingUploadsAfterReconnect() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        let data = try JSONSerialization.data(withJSONObject: ["server": "https://\(f.server.host)", "username": "test", "autoUpload": false, "keepOffline": false])
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        let store = try LibraryStore(root: f.root.appendingPathComponent("reconnect"), profile: profile, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        store.credentialAccess = NASCredentialAccess(load: { _ in nil }, save: { _, _, _ in })
        store.clientFactory = { url, allowed in NoteStationClient(baseURL: url, session: f.server.session, allowsValidatedWrites: allowed) }
        defer { store.uploadLoop?.cancel(); store.uploadTask?.cancel(); store.refreshTask?.cancel(); store.offlineTask?.cancel() }
        let id = try #require(await store.newNote(notebookID: "book"))
        #expect(f.server.counts().creates == 0)
        await store.connect(profile: profile, password: "test")
        #expect(store.isConnected)
        #expect(store.client?.capabilities.supportsWrites == true)
        for _ in 0..<60 {
            if try await store.repository.note(id: id)?.syncState == .synced { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await store.repository.note(id: id)?.syncState == .synced)
        #expect(f.server.counts().creates == 1)
        #expect(try await store.repository.pendingOperations().isEmpty)
        let persisted = try #require(store.preferences.data(forKey: "connectionProfile"))
        let settings = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        #expect(settings["autoUpload"] == nil)
    }

    @Test func legacyLocalNotebookIsCreatedOnNASAndItsNoteAndAttachmentUploadAutomatically() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        let store = try makeStore(f)
        defer { store.uploadLoop?.cancel(); store.uploadTask?.cancel(); store.offlineTask?.cancel() }
        try await store.repository.setNotebooks([Notebook(id: "local-markdown", name: "markdown")])
        let asset = try await store.attachments.importData(Data("attachment".utf8), name: "test.txt")
        var draft = NoteRecord(title: "Test", notebookID: "local-markdown", markdown: "# 제목\n- 안녕?\n\n[파일](\(asset.reference))")
        draft.attachments = [asset]
        let saved = try await store.repository.save(draft, enqueue: false)
        let session = try #require(await store.session(for: saved.id))
        await store.pushPendingUploads()
        let uploaded = try #require(try await store.repository.note(id: saved.id))
        let remoteID = try #require(uploaded.remoteID)
        let remote = try await f.client.fetch(noteID: remoteID)
        #expect(uploaded.syncState == .synced && remote.html.contains("안녕?"))
        #expect(session.note.notebookID == uploaded.notebookID && uploaded.notebookID != "local-markdown")
        #expect(try await f.client.notebooks().contains { $0.id == uploaded.notebookID && $0.name == "markdown" })
        #expect(try await store.attachments.verifiedData(for: uploaded.attachments[0]) == Data("attachment".utf8))
        await store.pushPendingUploads()
        #expect(f.server.counts().creates == 1)
        #expect(try await store.repository.pendingOperations().isEmpty)
    }

    @Test func notebookDeletionMovesConfirmedNotesToServerTrashAndPreservesCachedCopy() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        let store = try makeStore(f)
        defer { store.uploadLoop?.cancel(); store.uploadTask?.cancel(); store.offlineTask?.cancel() }
        try await store.repository.setNotebooks([Notebook(id: "book", name: "NAS")])
        let id = try #require(await store.newNote(notebookID: "book"))
        await store.pushPendingUploads()
        store.uploadTask?.cancel()
        let before = try #require(try await store.repository.note(id: id))
        let remoteID = try #require(before.remoteID)
        // Finish a scheduled upload before testing deletion's idle-state guard.
        // Cancellation alone does not wait for an already running upload.
        await store.uploadTask?.value
        try await store.deleteNotebook(id: "book")
        #expect(try await f.client.fetch(noteID: remoteID).summary.isTrashed)
        #expect(try await store.repository.note(id: id)?.isTrashed == true)
        #expect(!store.notebooks.contains { $0.id == "book" })
        #expect(try await store.repository.pendingOperations().isEmpty)
    }

    @Test func failedTransportProducesPersistentDiagnosticCode() async throws {
        let f = try await ProductionFixture.make(loseCreate: true); defer { f.close() }
        let store = try makeStore(f)
        defer { store.uploadLoop?.cancel(); store.uploadTask?.cancel(); store.offlineTask?.cancel() }
        _ = try #require(await store.newNote(notebookID: "book"))
        await store.pushPendingUploads()
        let text = try String(contentsOf: store.logDirectory.appendingPathComponent("app.jsonl"), encoding: .utf8)
        #expect(text.contains("upload.failed"))
        #expect(text.contains("error_code") && text.contains("transport"))
        #expect(!text.contains("synthetic-sid"))
    }

    @Test func openingOwnUnconfirmedUploadDefersToSyncJournalInsteadOfRemoteMerge() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        f.server.normalizeCodeBlocksOnWrite(damageContent: true)
        let store = try makeStore(f)
        defer { store.uploadLoop?.cancel(); store.uploadTask?.cancel(); store.offlineTask?.cancel() }
        let note = try await store.repository.save(NoteRecord(notebookID: "book", markdown: "```mermaid\nA --> B[Preview]\n```"))
        await store.pushPendingUploads()
        let session = try #require(await store.session(for: note.id))
        let reads = f.server.readCount()
        await store.fetchContent(for: session)
        #expect(f.server.readCount() == reads)
        #expect(session.note.syncState == .failed && session.note.conflictHTML == nil)
        #expect(session.note.markdown == note.markdown)
    }

    private func makeStore(_ f: ProductionFixture) throws -> LibraryStore {
        let profile = ConnectionProfile(server: "https://\(f.server.host)", username: "test")
        let store = try LibraryStore(root: f.root.appendingPathComponent("app"), profile: profile, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        store.client = f.client; store.isConnected = true
        try store.configureUploads()
        return store
    }
}
