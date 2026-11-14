import Foundation
import Testing
@testable import NoteCore
@testable import SynologyNote

@Suite @MainActor struct TrashManagementTests {
    @Test func permanentlyDeletesConfirmedTrashOnNASAndPurgesLocalHistoryAndStalePulls() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        let store = try makeStore(f)
        defer { store.uploadTask?.cancel(); store.uploadLoop?.cancel() }
        let asset = try await store.attachments.importData(Data("delete me".utf8), name: "file.txt")
        var draft = NoteRecord(title: "휴지통 테스트", notebookID: "book", markdown: "[파일](\(asset.reference))")
        draft.isTrashed = true; draft.attachments = [asset]
        let saved = try await store.repository.save(draft)
        await store.pushPendingUploads()
        let session = try #require(await store.session(for: saved.id))
        let before = session.note
        try await store.permanentlyDelete(session)
        #expect(try await f.client.notes().isEmpty)
        #expect(try await store.repository.note(id: saved.id) == nil)
        #expect(try await store.repository.revisions(noteID: saved.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: await store.attachments.url(for: asset).path))
        try await store.repository.observeRemote(before)
        #expect(try await store.repository.note(id: saved.id) == nil)
        await #expect(throws: RepositoryError.self) { _ = try await store.repository.save(before) }
        #expect(f.server.deleteCount() == 1)
    }

    @Test func lostDeleteReceiptConfirmsAbsenceWithoutRepeatingDelete() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        let store = try makeStore(f)
        defer { store.uploadTask?.cancel(); store.uploadLoop?.cancel() }
        var draft = NoteRecord(notebookID: "book", markdown: "trash"); draft.isTrashed = true
        let saved = try await store.repository.save(draft)
        await store.pushPendingUploads()
        let session = try #require(await store.session(for: saved.id))
        f.server.loseNextDeleteResponse()
        try await store.permanentlyDelete(session)
        #expect(try await store.repository.note(id: saved.id) == nil)
        #expect(f.server.deleteCount() == 1)
    }

    @Test func activeNoteCannotBePermanentlyDeleted() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        var draft = try await f.repo.save(NoteRecord(notebookID: "book", markdown: "keep"))
        await f.coordinator.push(); draft = try #require(try await f.repo.note(id: draft.id))
        await #expect(throws: NoteStationError.self) { try await f.client.permanentlyDeleteNote(noteID: draft.remoteID!, baseVersion: draft.serverVersion!) }
        #expect(f.server.deleteCount() == 0)
    }

    @Test func unsuccessfulNASReadbackPreservesLocalNoteAndHistory() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        let store = try makeStore(f)
        defer { store.uploadTask?.cancel(); store.uploadLoop?.cancel() }
        var draft = NoteRecord(notebookID: "book", markdown: "keep until confirmed"); draft.isTrashed = true
        let saved = try await store.repository.save(draft)
        await store.pushPendingUploads()
        let session = try #require(await store.session(for: saved.id))
        f.server.keepNoteOnNextDelete()
        await #expect(throws: NoteStationError.invalidResponse) { try await store.permanentlyDelete(session) }
        #expect(try await store.repository.note(id: saved.id) != nil)
        #expect(try await !store.repository.revisions(noteID: saved.id).isEmpty)
        #expect(store.sessions[saved.id] === session)
    }

    @Test func sharedAttachmentCacheSurvivesPurgingAnotherNotesHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try NoteRepository(directory: root)
        let asset = NoteAttachment(name: "shared", filename: "shared.bin", sha256: "hash", byteCount: 1)
        var a = NoteRecord(notebookID: "book"); a.remoteID = "trash"; a.isTrashed = true; a.attachments = [asset]
        a = try await repo.save(a, enqueue: false)
        var b = NoteRecord(notebookID: "book"); b.attachments = [asset]
        b = try await repo.save(b, enqueue: false)
        b.attachments = []; _ = try await repo.save(b, enqueue: false)
        #expect(try await repo.purgeConfirmedTrash(noteID: a.id, remoteID: "trash").isEmpty)
        #expect(try await !repo.revisions(noteID: b.id).isEmpty)
    }

    private func makeStore(_ f: ProductionFixture) throws -> LibraryStore {
        let store = try LibraryStore(root: f.root.appendingPathComponent("app"), profile: ConnectionProfile(server: "https://\(f.server.host)", username: "test", keepOffline: false), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        store.client = f.client; store.isConnected = true
        try store.configureUploads()
        return store
    }
}
