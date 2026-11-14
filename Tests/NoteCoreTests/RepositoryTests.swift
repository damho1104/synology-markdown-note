import Foundation
import Testing
@testable import NoteCore

@Suite struct RepositoryTests {
    @Test func staleEditorSaveKeepsRemoteIDAndVersionAfterCreateCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try NoteRepository(directory: root)
        var stale = try await repo.save(NoteRecord(markdown: "最初"))
        let operation = try #require(try await repo.pendingOperations().first)
        let html = MarkdownPipeline.render(stale.markdown)
        let attempt = SyncAttempt(operation: operation, note: stale, html: html, source: Data())
        try await repo.beginSync(attempt)
        try await repo.completeSync(attempt, snapshot: SyncRemoteSnapshot(remoteID: "created-once", version: "v3", html: html, source: nil))
        stale.markdown = "最新の編集"
        let saved = try await repo.save(stale)
        #expect(saved.remoteID == "created-once")
        #expect(saved.serverVersion == "v3")
        #expect(try await repo.pendingOperations().first?.baseVersion == "v3")
        #expect(saved.markdown == "最新の編集")
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func saveSurvivesReopenWithHistoryAndQueue() async throws {
        let url = try directory()
        let repository = try NoteRepository(directory: url)
        var note = NoteRecord(title: "한글 노트", markdown: "첫 줄")
        note = try await repository.save(note)
        note.markdown = "두 번째 줄"
        note = try await repository.save(note)
        let reopened = try NoteRepository(directory: url)
        let saved = try await reopened.note(id: note.id)
        let history = try await reopened.revisions(noteID: note.id)
        let operations = try await reopened.pendingOperations()
        #expect(saved?.markdown == "두 번째 줄")
        #expect(history.count == 2)
        #expect(operations.count == 1)
        #expect(operations.first?.revision == 2)
    }

    @Test func readingAndImportingRemoteDoesNotEnqueueWrites() async throws {
        let repository = try NoteRepository(directory: directory())
        var remote = NoteRecord(title: "서버 노트", markdown: "", mode: .original)
        remote.remoteID = "remote-1"
        remote.serverVersion = "v2"
        remote.originalHTML = "<p>내용</p>"
        _ = try await repository.mergeRemote(remote)
        _ = try await repository.listNotes()
        _ = try await repository.note(id: remote.id)
        let pending = try await repository.pendingOperations()
        #expect(pending.isEmpty)
    }

    @Test func oldCompletionCannotClearNewerRevision() async throws {
        let repository = try NoteRepository(directory: directory())
        var note = try await repository.save(NoteRecord(title: "제목", markdown: "1"))
        let sentRevision = note.revision
        note.markdown = "2"
        note = try await repository.save(note)
        try await repository.acknowledge(noteID: note.id, revision: sentRevision, serverVersion: "v2")
        let pending = try await repository.pendingOperations()
        let saved = try await repository.note(id: note.id)
        #expect(pending.first?.revision == note.revision)
        #expect(saved?.markdown == "2")
        #expect(saved?.syncState == .pending)
    }

    @Test func externalEditPreservesBothSidesWhenLocalChangesExist() async throws {
        let repository = try NoteRepository(directory: directory())
        var remote = NoteRecord(title: "제목", mode: .original)
        remote.remoteID = "r1"; remote.serverVersion = "v1"; remote.originalHTML = "<p>기준</p>"
        _ = try await repository.mergeRemote(remote)
        var local = try #require(try await repository.note(id: remote.id))
        local.markdown = "로컬 편집"; local.mode = .markdown
        local = try await repository.save(local)
        remote.serverVersion = "v2"; remote.originalHTML = "<p>외부 편집</p>"
        remote.attachments = [NoteAttachment(name: "서버 이미지.png", filename: "copied.png", sha256: "hash", byteCount: 1, remoteID: "file-new")]
        let merged = try await repository.mergeRemote(remote)
        #expect(merged.markdown == "로컬 편집")
        #expect(merged.conflictHTML == "<p>외부 편집</p>")
        #expect(merged.syncState == .conflict)
        #expect(merged.conflictSnapshot?.attachments.first?.remoteID == "file-new")
    }

    @Test func copiedAttachmentSurvivesOriginalDeletionAndRejectsCorruption() async throws {
        let root = try directory()
        let store = try AttachmentStore(directory: root.appendingPathComponent("assets"))
        let original = root.appendingPathComponent(String(repeating: "가", count: 60) + ".png")
        try Data([1,2,3,4]).write(to: original)
        let attachment = try await store.importFile(original)
        try FileManager.default.removeItem(at: original)
        let data = try await store.verifiedData(for: attachment)
        #expect(data == Data([1,2,3,4]))
        let storedURL = await store.url(for: attachment)
        try Data([9]).write(to: storedURL)
        do {
            _ = try await store.verifiedData(for: attachment)
            Issue.record("손상된 첨부를 전송에 사용하면 안 됨")
        } catch { #expect(error is AttachmentError) }
    }

    @Test func failureOnOneNoteDoesNotHideIndependentQueueItems() async throws {
        let repository = try NoteRepository(directory: directory())
        let first = try await repository.save(NoteRecord(title: "A"))
        let second = try await repository.save(NoteRecord(title: "B"))
        try await repository.fail(noteID: first.id, message: "첨부 없음")
        let pending = try await repository.pendingOperations()
        #expect(Set(pending.map(\.noteID)) == Set([first.id,second.id]))
        #expect(pending.first(where: { $0.noteID == first.id })?.state == .failed)
        #expect(pending.first(where: { $0.noteID == second.id })?.state == .pending)
    }

    @Test func listVersionDoesNotAdvanceFailedBodyVersion() async throws {
        let repository = try NoteRepository(directory: directory())
        var note = NoteRecord(title: "원격", mode: .original)
        note.remoteID = "r1"; note.serverVersion = "v1"; note.originalHTML = "<p>첫 본문</p>"
        _ = try await repository.mergeRemote(note)
        note.serverVersion = "v2"; note.listedVersion = "v2"; note.originalHTML = ""
        try await repository.observeRemote(note)
        let saved = try await repository.note(remoteID: "r1")
        #expect(saved?.serverVersion == "v1")
        #expect(saved?.listedVersion == "v2")
        #expect(saved?.originalHTML == "<p>첫 본문</p>")
    }
    @Test func oldCommitLinksRemoteIDAndKeepsNewerDraftQueued() async throws {
        let repository = try NoteRepository(directory: directory())
        var note = try await repository.save(NoteRecord(markdown: "첫 수정"))
        let operation = try #require(try await repository.pendingOperations().first)
        let attempt = SyncAttempt(operation: operation, note: note, html: "<p>첫 수정</p>", source: Data())
        try await repository.beginSync(attempt)
        note.markdown = "새 수정"; note = try await repository.save(note)
        try await repository.completeSync(attempt, snapshot: SyncRemoteSnapshot(remoteID: "created", version: "v1", html: "<p>첫 수정</p>", source: nil))
        let saved = try await repository.note(id: note.id)
        let queued = try #require(try await repository.pendingOperations().first)
        #expect(saved?.remoteID == "created")
        #expect(saved?.markdown == "새 수정")
        #expect(saved?.syncState == .pending)
        #expect(queued.baseVersion == "v1")
        #expect(queued.revision == note.revision)
    }
    @Test func blockDeletionAndUndoKeepPayloadWithoutBlankingDocument() {
        let imported = MarkdownPipeline.importHTML("<p>앞</p><table><tr><td colspan=\"2\">원본</td></tr></table><p>뒤</p>")
        var note = NoteRecord(markdown: imported.markdown)
        note.blocks = imported.blocks
        let before = note.markdown
        note.markdown = note.markdown.replacingOccurrences(of: MarkdownPipeline.token(for: imported.blocks[0]), with: "")
        let rendered = MarkdownPipeline.render(note.markdown, blocks: note.activeBlocks)
        #expect(rendered.contains("앞"))
        #expect(!rendered.contains("table"))
        note.markdown = before
        #expect(MarkdownPipeline.render(note.markdown, blocks: note.activeBlocks).contains("colspan=\"2\""))
    }
}
