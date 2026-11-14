import Foundation
import Testing
import CSQLite
@testable import NoteCore

@Suite struct DatabaseMaintenanceTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("db-maintenance-\(UUID().uuidString)")
    }

    private func runSQL(_ sql: String, in directory: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("notes.sqlite3").path, &db) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw RepositoryError(message: "테스트 DB를 열지 못했습니다.")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw RepositoryError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func count(_ sql: String, in directory: URL) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("notes.sqlite3").path, &db) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw RepositoryError(message: "테스트 DB를 열지 못했습니다.")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RepositoryError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw RepositoryError(message: "테스트 쿼리 실패") }
        return sqlite3_column_int64(statement, 0)
    }

    @Test func identicalSearchTextDoesNotCreateExtraFTSRows() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try NoteRepository(directory: root)
        var note = try await repo.save(NoteRecord(title: "한글 검색", markdown: "Unicode%_입력"), enqueue: false)
        for _ in 0..<10 { note = try await repo.save(note, enqueue: false) }
        #expect(try count("SELECT count(*) FROM search_fts", in: root) == 1)
        #expect(try count("SELECT count(*) FROM search_documents", in: root) == 1)
        #expect(try await repo.searchNoteIDs("글 검색") == [note.id])
        #expect(try await repo.searchNoteIDs("%_입력") == [note.id])
    }

    @Test func legacyReplaceOrphansAreRepairedBeforeNewWrites() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var repo: NoteRepository? = try NoteRepository(directory: root)
        let first = try await repo!.save(NoteRecord(title: "첫 번째", markdown: "첫문서검색"), enqueue: false)
        _ = try await repo!.save(NoteRecord(title: "두 번째", markdown: "두번째검색"), enqueue: false)
        repo = nil
        try runSQL("INSERT OR REPLACE INTO search_documents(id,text) VALUES ('\(first.id.uuidString)', '교체된검색텍스트')", in: root)
        #expect(try count("SELECT count(*) FROM search_fts", in: root) > 2)
        let reopened = try NoteRepository(directory: root)
        #expect(try await reopened.searchNoteIDs("두번째검") .count == 1)
        #expect(try await reopened.searchNoteIDs("교체된검") == [first.id])
        #expect(try count("SELECT count(*) FROM search_fts", in: root) == 2)
        #expect(DatabaseMaintenance.snapshots(in: root).count == 1)
        #expect(try await reopened.listNotes().count == 2)
    }

    @Test func bloatedLegacyIndexShrinksOnLaunchWithoutLosingHistoryOrPendingWrites() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var repo: NoteRepository? = try NoteRepository(directory: root)
        var note = try await repo!.save(NoteRecord(title: "보존할 노트", markdown: "첫 번째 편집"))
        note.markdown = "최신검색문자열"
        note = try await repo!.save(note)
        let revisionIDs = try await repo!.revisions(noteID: note.id).map(\.id)
        repo = nil
        // Reproduce the legacy REPLACE path: old rowids remain in the FTS
        // table while the single search document receives a new rowid.
        let text = String(repeating: "과거검색내용 ", count: 1200)
        let replaces = (0..<240).map { index in
            "INSERT OR REPLACE INTO search_documents(id,text) VALUES ('\(note.id.uuidString)', '\(index) \(text)');"
        }.joined()
        try runSQL("BEGIN; \(replaces) COMMIT; PRAGMA wal_checkpoint(TRUNCATE);", in: root)
        let before = try count("PRAGMA page_count", in: root) * count("PRAGMA page_size", in: root)
        #expect(try count("SELECT count(*) FROM search_fts", in: root) == 241)

        var reopened: NoteRepository? = try NoteRepository(directory: root)
        #expect(try await reopened!.note(id: note.id)?.markdown == "최신검색문자열")
        #expect(try await reopened!.revisions(noteID: note.id).map(\.id) == revisionIDs)
        #expect(try await reopened!.pendingOperations().map(\.noteID) == [note.id])
        #expect(try count("SELECT count(*) FROM search_fts", in: root) == 1)
        // Exercise MATCH directly: searchNoteIDs also has a substring fallback.
        #expect(try count("SELECT count(*) FROM search_fts JOIN search_documents d ON d.rowid=search_fts.rowid WHERE search_fts MATCH '과거검색내용'", in: root) == 1)
        #expect(try count("PRAGMA freelist_count", in: root) == 0)
        let after = try count("PRAGMA page_count", in: root) * count("PRAGMA page_size", in: root)
        let fileBytes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("notes.sqlite3").path)[.size] as? Int64
        #expect(after < before / 4)
        #expect(fileBytes == after)
        let backup = try #require(DatabaseMaintenance.snapshots(in: root).first)
        try DatabaseMaintenance.validateBackup(at: backup.url)
        #expect(backup.size >= before)
        print("Legacy FTS cleanup: \(before) -> \(after) bytes (backup retained separately)")
        reopened = nil
        _ = try NoteRepository(directory: root)
        #expect(DatabaseMaintenance.snapshots(in: root).count == 1)
    }

    @Test func launchRetriesSpaceReclamationAfterAnAlreadyCommittedRepair() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var repo: NoteRepository? = try NoteRepository(directory: root)
        let note = try await repo!.save(NoteRecord(markdown: "정상검색문서"))
        repo = nil
        // Simulate an interrupted maintenance run: the FTS table is healthy,
        // but dropped pages have not yet been returned to the filesystem.
        try runSQL("CREATE TABLE discarded(data BLOB); INSERT INTO discarded VALUES (zeroblob(8*1024*1024)); DROP TABLE discarded; PRAGMA wal_checkpoint(TRUNCATE);", in: root)
        #expect(try count("PRAGMA freelist_count", in: root) > 1000)
        let before = try count("PRAGMA page_count", in: root)
        let reopened = try NoteRepository(directory: root)
        #expect(try count("PRAGMA freelist_count", in: root) == 0)
        #expect(try count("PRAGMA page_count", in: root) < before / 4)
        #expect(try await reopened.searchNoteIDs("정상검색문서") == [note.id])
        #expect(try await reopened.revisions(noteID: note.id).count == 1)
        #expect(try await reopened.pendingOperations().map(\.noteID) == [note.id])
        #expect(DatabaseMaintenance.snapshots(in: root).count == 1)
    }

    @Test func equalCountsStillRepairOrphansAndMissingDocuments() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var repo: NoteRepository? = try NoteRepository(directory: root)
        let note = try await repo!.save(NoteRecord(title: "정상 제목", markdown: "검색할내용"), enqueue: false)
        repo = nil
        try runSQL("DELETE FROM search_fts; INSERT INTO search_fts(rowid,text) VALUES (9999,'고아색인내용')", in: root)
        #expect(try count("SELECT count(*) FROM search_fts", in: root) == 1)
        let reopened = try NoteRepository(directory: root)
        #expect(try await reopened.searchNoteIDs("검색할내용") == [note.id])
        #expect(try count("SELECT count(*) FROM search_fts WHERE rowid=9999", in: root) == 0)
        #expect(DatabaseMaintenance.snapshots(in: root).count == 1)
    }

    @Test func snapshotsPreserveRevisionsPendingWritesAndWAL() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var repo: NoteRepository? = try NoteRepository(directory: root)
        var note = try await repo!.save(NoteRecord(title: "초안", markdown: "첫 내용"))
        note.markdown = "수정 내용"
        note = try await repo!.save(note)
        let snapshot = try #require(try await repo!.backupIfNeeded(force: true))
        #expect(try await repo!.backupIfNeeded() == nil)
        try DatabaseMaintenance.validateBackup(at: snapshot)
        note.markdown = "백업 이후 변경"
        _ = try await repo!.save(note)
        repo = nil
        _ = try DatabaseMaintenance.restore(snapshot, in: root)
        let restored = try NoteRepository(directory: root)
        #expect(try await restored.note(id: note.id)?.markdown == "수정 내용")
        #expect(try await restored.revisions(noteID: note.id).count == 2)
        #expect(try await restored.pendingOperations().map(\.noteID) == [note.id])
    }

    @Test func rollbackRestoresOriginalAfterFailedLaunch() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var repo: NoteRepository? = try NoteRepository(directory: root)
        var note = try await repo!.save(NoteRecord(title: "메모", markdown: "이전"), enqueue: false)
        let snapshot = try #require(try await repo!.backupIfNeeded(force: true))
        note.markdown = "최신 변경"
        note = try await repo!.save(note, enqueue: false)
        repo = nil
        let quarantine = try DatabaseMaintenance.restore(snapshot, in: root)
        try DatabaseMaintenance.rollbackRestore(in: root, from: quarantine)
        let reopened = try NoteRepository(directory: root)
        #expect(try await reopened.note(id: note.id)?.markdown == "최신 변경")
        #expect(try await reopened.revisions(noteID: note.id).count == 2)
    }

    @Test func unavailableRollbackOriginalDoesNotDeleteRestoredDatabase() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var repo: NoteRepository? = try NoteRepository(directory: root)
        let note = try await repo!.save(NoteRecord(markdown: "복구한 내용"), enqueue: false)
        let backup = try #require(try await repo!.backupIfNeeded(force: true))
        repo = nil
        let quarantine = try DatabaseMaintenance.restore(backup, in: root)
        try FileManager.default.removeItem(at: quarantine.appendingPathComponent("notes.sqlite3"))
        #expect(throws: Error.self) { try DatabaseMaintenance.rollbackRestore(in: root, from: quarantine) }
        let reopened = try NoteRepository(directory: root)
        #expect(try await reopened.note(id: note.id)?.markdown == "복구한 내용")
    }

    @Test func restoreKeepsRevisionAttachmentReferencesAndAssetBytes() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = try AttachmentStore(directory: root.appendingPathComponent("assets"))
        let bytes = Data("원본 첨부파일".utf8)
        let attachment = try await files.importData(bytes, name: "기록.txt")
        var repo: NoteRepository? = try NoteRepository(directory: root)
        var note = NoteRecord(title: "첨부 이력")
        note.attachments = [attachment]
        note = try await repo!.save(note)
        note.markdown = "두 번째 편집"
        note = try await repo!.save(note)
        let backup = try #require(try await repo!.backupIfNeeded(force: true))
        note.markdown = "백업 이후 수정"
        _ = try await repo!.save(note)
        repo = nil
        _ = try DatabaseMaintenance.restore(backup, in: root)
        let reopened = try NoteRepository(directory: root)
        let restored = try #require(try await reopened.note(id: note.id))
        let revisions = try await reopened.revisions(noteID: note.id)
        #expect(restored.attachments == [attachment])
        #expect(revisions.count == 2)
        #expect(revisions.allSatisfy { $0.note.attachments == [attachment] })
        #expect(try await files.verifiedData(for: attachment) == bytes)
    }

    @Test func backupsRemainIsolatedAcrossAccountDirectories() async throws {
        let a = directory(), b = directory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let first = try NoteRepository(directory: a)
        let second = try NoteRepository(directory: b)
        let firstNote = try await first.save(NoteRecord(markdown: "A 계정"), enqueue: false)
        let secondNote = try await second.save(NoteRecord(markdown: "B 계정"), enqueue: false)
        _ = try await first.backupIfNeeded(force: true)
        _ = try await second.backupIfNeeded(force: true)
        let aBackup = try #require(DatabaseMaintenance.snapshots(in: a).first?.url)
        let bBackup = try #require(DatabaseMaintenance.snapshots(in: b).first?.url)
        #expect(aBackup != bBackup)
        #expect(DatabaseMaintenance.snapshots(in: a).count == 1)
        #expect(DatabaseMaintenance.snapshots(in: b).count == 1)
        #expect(try await first.note(id: secondNote.id) == nil)
        #expect(try await second.note(id: firstNote.id) == nil)
    }

    @Test func corruptBackupAndWrongAccountCannotReplaceLiveDatabase() async throws {
        let a = directory(), b = directory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        var first: NoteRepository? = try NoteRepository(directory: a)
        let note = try await first!.save(NoteRecord(markdown: "보존할내용"), enqueue: false)
        let snapshot = try #require(try await first!.backupIfNeeded(force: true))
        first = nil
        var second: NoteRepository? = try NoteRepository(directory: b)
        _ = try await second!.save(NoteRecord(markdown: "별도계정"), enqueue: false)
        second = nil
        do { _ = try DatabaseMaintenance.restore(snapshot, in: b); Issue.record("다른 계정 백업을 허용함") }
        catch { }
        let fake = a.appendingPathComponent("backups/snapshot-corrupt.sqlite3")
        try Data("not a database".utf8).write(to: fake)
        do { _ = try DatabaseMaintenance.restore(fake, in: a); Issue.record("손상 백업을 허용함") }
        catch { }
        let reopened = try NoteRepository(directory: a)
        #expect(try await reopened.note(id: note.id) != nil)
    }

    @Test func corruptLocalDatabaseIsNotAutomaticallyReplaced() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = root.appendingPathComponent("notes.sqlite3")
        let content = Data("irrecoverable sqlite content".utf8)
        try content.write(to: db)
        do { _ = try NoteRepository(directory: root); Issue.record("손상 DB를 자동 초기화함") }
        catch { }
        #expect(try Data(contentsOf: db) == content)
    }

    @Test func missingDatabaseWithBackupRequiresRecoveryInsteadOfEmptyLibrary() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var repo: NoteRepository? = try NoteRepository(directory: root)
        let note = try await repo!.save(NoteRecord(markdown: "백업에서 찾을 메모"), enqueue: false)
        let snapshot = try #require(try await repo!.backupIfNeeded(force: true))
        repo = nil

        try FileManager.default.removeItem(at: root.appendingPathComponent("notes.sqlite3"))
        #expect(throws: RepositoryError.self) { _ = try NoteRepository(directory: root) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("notes.sqlite3").path))

        _ = try DatabaseMaintenance.restore(snapshot, in: root)
        let restored = try NoteRepository(directory: root)
        #expect(try await restored.note(id: note.id)?.markdown == "백업에서 찾을 메모")
    }
}
