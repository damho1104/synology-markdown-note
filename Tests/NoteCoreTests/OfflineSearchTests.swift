import Foundation
import Testing
@testable import NoteCore
@testable import SynologyNote

@Suite struct OfflineSearchTests {
    @Test @MainActor func failedAttachmentDoesNotBlockOtherClosedNotesOrOverwritePendingDraft() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        var remoteIDs: [String] = []
        for index in 0..<3 {
            let file = try await f.assets.importData(Data("file-\(index)".utf8), name: "자료\(index).txt")
            var note = NoteRecord(title: "closed-\(index)", notebookID: "book", markdown: "검색 본문 \(index)\n[자료](\(file.reference))")
            note.attachments = [file]
            note = try await f.repo.save(note)
            await f.coordinator.push()
            remoteIDs.append(try #require(try await f.repo.note(id: note.id)?.remoteID))
        }
        f.server.failDownloads(for: remoteIDs[0])
        let profile = ConnectionProfile(server: "https://\(f.server.host)", username: "test")
        let store = try LibraryStore(root: f.root.appendingPathComponent("offline-failures"), profile: profile, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        store.client = f.client; store.isConnected = true
        for summary in try await f.client.notes() { try await store.repository.observeRemote(LibraryStore.record(from: summary)) }
        var draft = try #require(try await store.repository.note(remoteID: remoteIDs[2]))
        draft.markdown = "로컬 미전송 초안"; draft.mode = .markdown
        draft = try await store.repository.save(draft)
        store.startOfflineDownload()
        await store.offlineTask?.value
        #expect(store.offlineFailures.count == 1)
        #expect(try await store.repository.note(remoteID: remoteIDs[1])?.hasRemoteContent == true)
        #expect(try await store.repository.note(id: draft.id)?.markdown == "로컬 미전송 초안")
        #expect(try await store.repository.pendingOperations().map(\.noteID) == [draft.id])
    }

    @Test @MainActor func unopenedRemoteNoteAndAttachmentsAreAvailableAfterOfflineRestart() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        let file = try await f.assets.importData(Data("오프라인 첨부 원본".utf8), name: "자료.txt")
        var remote = NoteRecord(title: "닫힌 문서", notebookID: "book", markdown: "오프라인으로 검색할 긴 본문\n[자료](\(file.reference))")
        remote.attachments = [file]
        _ = try await f.repo.save(remote)
        await f.coordinator.push()
        let profile = ConnectionProfile(server: "https://\(f.server.host)", username: "test")
        let root = f.root.appendingPathComponent("offline-app")
        let store = try LibraryStore(root: root, profile: profile, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        store.client = f.client; store.isConnected = true
        for summary in try await f.client.notes() { try await store.repository.observeRemote(LibraryStore.record(from: summary)) }
        #expect(store.sessions.isEmpty)
        store.startOfflineDownload()
        await store.offlineTask?.value
        #expect(store.offlineFailures.isEmpty)
        #expect(try await store.repository.offlineCandidates().isEmpty)
        let reopened = try LibraryStore(root: root, profile: profile, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let ids = try await reopened.repository.searchNoteIDs("검색할 긴")
        let id = try #require(ids.first)
        let session = try #require(await reopened.session(for: id))
        #expect(session.note.markdown == remote.markdown)
        let attachment = try #require(session.note.attachments.first(where: { $0.remoteID != nil && $0.name == "자료.txt" }))
        #expect(try await reopened.attachments.verifiedData(for: attachment) == Data("오프라인 첨부 원본".utf8))
        #expect(try await reopened.repository.pendingOperations().isEmpty)
    }

    @Test func indexPreservesKoreanPartialAndLiteralSearchAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try NoteRepository(directory: root)
        var note = NoteRecord(title: "표제", markdown: "긴 문서의 오프라인검색과 100%_literal")
        note = try await repo.save(note, enqueue: false)
        let restarted = try NoteRepository(directory: root)
        #expect(try await restarted.searchNoteIDs("프라인검") == [note.id])
        #expect(try await restarted.searchNoteIDs("100%_literal") == [note.id])
        #expect(try await restarted.searchNoteIDs("LITERAL") == [note.id])
        #expect(try await restarted.pendingOperations().isEmpty)
    }

    @Test func offlineCandidatesExcludeLockedAndCurrentBodiesButIncludeStaleBodies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try NoteRepository(directory: root)
        for (id, mode) in [("open", DocumentMode.original), ("locked", .locked)] {
            var record = NoteRecord(title: id, mode: mode)
            record.remoteID = id; record.serverVersion = "v1"
            try await repo.observeRemote(record)
        }
        #expect(try await repo.offlineCandidates().map(\.remoteID) == ["open"])
        var content = NoteRecord(title: "open", mode: .original)
        content.remoteID = "open"; content.serverVersion = "v1"; content.originalHTML = "<p>캐시된 본문</p>"
        _ = try await repo.mergeRemote(content)
        #expect(try await repo.offlineCandidates().isEmpty)
        content.serverVersion = "v2"
        try await repo.observeRemote(content)
        #expect(try await repo.offlineCandidates().map(\.remoteID) == ["open"])
    }
}
