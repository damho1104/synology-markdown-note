import Foundation
import Testing
import CSQLite
@testable import NoteCore

@Suite struct SyncTests {
    @Test func conflictPersistenceFailureKeepsRecoveryJournal() async throws {
        let (repo, _, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = NoteRecord(markdown: "keep local")
        note.remoteID = "r1"; note.serverVersion = "v1"
        note = try await repo.save(note)
        let operation = try #require(try await repo.pendingOperations().first)
        try await repo.beginSync(SyncAttempt(operation: operation, note: note, html: "local", source: Data()))
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("notes.sqlite3").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TRIGGER fail_writes BEFORE INSERT ON notes BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END", nil, nil, nil) == SQLITE_OK)
        let transport = ConflictJournalTransport()
        let coordinator = SyncCoordinator(repository: repo, attachments: try AttachmentStore(directory: root.appendingPathComponent("assets")), transport: transport)
        await coordinator.push()
        #expect(await transport.finishCount == 0)
        #expect(try await repo.syncAttempts().count == 1)
    }
    func setup() throws -> (NoteRepository, AttachmentStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try NoteRepository(directory: root), try AttachmentStore(directory: root.appendingPathComponent("assets")), root)
    }
    @Test func missingAttachmentBlocksOnlyItsOwnNote() async throws {
        let (repo, assets, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var bad = NoteRecord(title: "첨부 누락")
        bad.attachments = [NoteAttachment(name: "missing.png", filename: UUID().uuidString, sha256: "no", byteCount: 4)]
        let first = try await repo.save(bad)
        let good = try await repo.save(NoteRecord(title: "독립 노트", markdown: "# 성공"))
        let transport = MemorySyncTransport()
        let coordinator = SyncCoordinator(repository: repo, attachments: assets, transport: transport)
        await coordinator.push()
        let failed = try await repo.note(id: first.id)
        let successful = try await repo.note(id: good.id)
        #expect(failed?.syncState == .failed)
        #expect(successful?.syncState == .synced)
    }
    @Test func lostResponseReconcilesBeforeRetryingCreation() async throws {
        let (repo, assets, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await repo.save(NoteRecord(markdown: "# 한 번만 생성"))
        let transport = MemorySyncTransport(loseFirstResponse: true)
        let first = SyncCoordinator(repository: repo, attachments: assets, transport: transport)
        await first.push()
        let uncertain = try await repo.syncAttempts()
        #expect(uncertain.count == 1)
        let restarted = SyncCoordinator(repository: repo, attachments: assets, transport: transport)
        await restarted.push()
        let saved = try await repo.note(id: note.id)
        let count = await transport.writeCount
        #expect(count == 1)
        #expect(saved?.syncState == .synced)
    }
    @Test func externallyChangedVersionPreventsWriteAndPreservesLocal() async throws {
        let (repo, assets, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = NoteRecord(markdown: "로컬 수정")
        note.remoteID = "r1"; note.serverVersion = "v1"; note.baseHTML = "<p>기준</p>"
        note = try await repo.save(note)
        let transport = MemorySyncTransport(external: SyncRemoteSnapshot(remoteID: "r1", version: "v2", html: "<p>외부 수정</p>", source: nil))
        let coordinator = SyncCoordinator(repository: repo, attachments: assets, transport: transport)
        await coordinator.push()
        let saved = try await repo.note(id: note.id)
        let count = await transport.writeCount
        #expect(count == 0)
        #expect(saved?.markdown == "로컬 수정")
        #expect(saved?.conflictHTML == "<p>외부 수정</p>")
    }
    @Test func confirmedNotAppliedRestoresRetryableOperation() async throws {
        let (repo, assets, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await repo.save(NoteRecord(markdown: "# 다시 시도"))
        let operation = try #require(try await repo.pendingOperations().first)
        let html = MarkdownPipeline.render(note.markdown)
        let attempt = SyncAttempt(operation: operation, note: note, html: html, source: SourceEnvelope(documentID: note.id, markdown: note.markdown, blocks: [], html: html).encoded())
        try await repo.beginSync(attempt)
        try await repo.fail(noteID: note.id, message: "응답 유실", uncertain: true)
        let transport = MemorySyncTransport(confirmNotApplied: true)
        let coordinator = SyncCoordinator(repository: repo, attachments: assets, transport: transport)
        await coordinator.push()
        let saved = try await repo.note(id: note.id)
        #expect(saved?.syncState == .synced)
        #expect(await transport.writeCount == 1)
    }
}

private actor ConflictJournalTransport: SyncTransport {
    var finishCount = 0
    let snapshot = SyncRemoteSnapshot(remoteID: "r1", version: "v2", html: "remote", source: nil)
    func fetch(remoteID: String) async throws -> SyncRemoteSnapshot { snapshot }
    func write(_ payload: SyncWritePayload) async throws -> SyncRemoteSnapshot { throw SyncError.uncertain }
    func reconcile(_ attempt: SyncAttempt) async throws -> SyncReconciliation { throw SyncError.remoteChanged(snapshot) }
    func finish(operationID: UUID) async { finishCount += 1 }
}

private actor MemorySyncTransport: SyncTransport {
    var writeCount = 0
    var stored: [UUID: SyncRemoteSnapshot] = [:]
    var loseFirstResponse: Bool
    var external: SyncRemoteSnapshot?
    var confirmNotApplied: Bool
    init(loseFirstResponse: Bool = false, external: SyncRemoteSnapshot? = nil, confirmNotApplied: Bool = false) { self.loseFirstResponse = loseFirstResponse; self.external = external; self.confirmNotApplied = confirmNotApplied }
    func fetch(remoteID: String) async throws -> SyncRemoteSnapshot { external ?? stored.values.first! }
    func write(_ payload: SyncWritePayload) async throws -> SyncRemoteSnapshot {
        writeCount += 1
        let result = SyncRemoteSnapshot(remoteID: payload.note.remoteID ?? UUID().uuidString, version: "v\(writeCount)", html: payload.html, source: payload.source)
        stored[payload.operationID] = result
        if loseFirstResponse { loseFirstResponse = false; throw URLError(.networkConnectionLost) }
        return result
    }
    func reconcile(_ attempt: SyncAttempt) async throws -> SyncReconciliation {
        if let result = stored[attempt.operation.id] { return .applied(result) }
        if confirmNotApplied { return .notApplied }
        return .unknown
    }
}
