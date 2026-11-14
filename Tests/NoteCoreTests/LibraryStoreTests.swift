import Foundation
import Testing
@testable import SynologyNote
import NoteCore

@Suite @MainActor struct LibraryStoreTests {
    @Test func newNoteWithLargeLibraryBenchmark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ConnectionProfile(server: "https://nas.example", username: "benchmark")
        let store = try LibraryStore(root: root, profile: profile, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        for index in 0..<1200 {
            _ = try await store.repository.save(NoteRecord(title: "테스트 \(index)", notebookID: "book", markdown: "[연결](테스트.md)"), enqueue: false)
        }
        try await store.repository.saveSearch(SavedSearch(name: "검색 1", query: "테스트"))
        try await store.repository.saveSearch(SavedSearch(name: "검색 2", query: "연결"))
        await store.load()
        let started = ProcessInfo.processInfo.systemUptime
        let id = try #require(await store.newNote(notebookID: "book"))
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        print("PERF newNote 1200 notes / 2 searches elapsed_ms: \(elapsed)")
        #expect(store.sessions[id] != nil)
        #expect(store.summaries.first?.id == id)
        #expect(store.noteGraph.nodes.contains { $0.id == id })
        #expect(try await store.repository.note(id: id)?.syncState == .pending)
        #expect(try await store.repository.pendingOperations().contains { $0.noteID == id })
        #expect(try await store.repository.revisions(noteID: id).count == 1)
        await store.localReloadTask?.value
        #expect(store.summaries.count == 1201)
        #expect(store.errorMessage == nil)
    }

    @Test func directEditsCannotQueueAnUndownloadedBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        var shell = NoteRecord(title: "다운로드 전", notebookID: "book", mode: .original)
        shell.remoteID = "remote-shell"; shell.hasRemoteContent = false
        let saved = try await store.repository.save(shell, enqueue: false)
        let session = try #require(await store.session(for: saved.id))
        store.edit(session) { $0.title = "아직 수정하면 안 됨" }
        await store.flush()
        #expect(session.note.title == "다운로드 전")
        #expect(try await store.repository.pendingOperations().isEmpty)
        #expect(store.errorMessage != nil)
    }

    @Test func savedEditsUpdateVisibleRowThenReconcileSmartSearchAndGraph() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let target = try await store.repository.save(NoteRecord(title: "대상"), enqueue: false)
        let source = try await store.repository.save(NoteRecord(title: "초기 제목"), enqueue: false)
        let search = SavedSearch(name: "본문 검색", query: "새로운 본문")
        try await store.repository.saveSearch(search)
        await store.load()
        let session = try #require(await store.session(for: source.id))
        store.edit(session) { $0.title = "바뀐 제목"; $0.markdown = "새로운 본문 [대상](대상.md)" }
        await store.flush()
        #expect(store.summaries.first?.title == "바뀐 제목")
        #expect(store.noteGraph.nodes.first { $0.id == source.id }?.title == "바뀐 제목")
        #expect(try await store.repository.note(id: source.id)?.markdown == session.note.markdown)
        await store.localReloadTask?.value
        #expect(store.filtered(.smart(search.id)).map(\.id) == [source.id])
        #expect(store.noteGraph.edges.contains { $0.sourceID == source.id && $0.targetID == target.id })
        #expect(store.errorMessage == nil)
    }
    @Test func concurrentOpeningSharesOneEditorSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile())
        let note = try await store.repository.save(NoteRecord(title: "공유 문서"))
        async let first = store.session(for: note.id)
        async let second = store.session(for: note.id)
        let (a, b) = await (first, second)
        #expect(a === b)
    }
    @Test func oldAccountSessionCannotBeEditedOrSavedIntoNewWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let profile = ConnectionProfile(server: "https://nas.example", username: "account-a")
        let store = try LibraryStore(root: root, profile: profile, preferences: preferences)
        let id = try #require(await store.newNote(notebookID: "book"))
        let oldSession = try #require(await store.session(for: id))
        store.accountGeneration += 1
        store.repository = try NoteRepository(directory: root.appendingPathComponent("account-b"))
        store.sessions = [:]
        store.summaries = []
        store.edit(oldSession) { $0.markdown = "다른 계정의 내용" }
        await store.save(oldSession)
        let wrong = try await store.repository.note(id: id)
        #expect(wrong == nil)
        #expect(oldSession.note.markdown.isEmpty)
        await store.localReloadTask?.value
        #expect(store.summaries.allSatisfy { $0.id != id })
    }
    @Test func previewTaskChangeIsUndoableThroughSharedSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile())
        let saved = try await store.repository.save(NoteRecord())
        let id = saved.id
        let session = try #require(await store.session(for: id))
        session.note.markdown = "- [ ] 작업"
        session.undoManager.groupsByEvent = false
        session.undoManager.beginUndoGrouping()
        store.edit(session, registerUndo: true) { $0.markdown = MarkdownEditing.toggleTask($0.markdown, line: 1) }
        session.undoManager.endUndoGrouping()
        session.undoManager.undo()
        #expect(session.note.markdown == "- [ ] 작업")
        session.undoManager.redo()
        #expect(session.note.markdown == "- [x] 작업")
    }

    @Test func savedSmartNotebookFiltersNotesAndStaysAccountLocal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProfile = ConnectionProfile(server: "https://nas.example", username: "first")
        let store = try LibraryStore(root: root, profile: firstProfile, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        var matching = NoteRecord(title: "프로젝트 계획", notebookID: "work", markdown: "검토 내용")
        matching.tags = ["업무"]
        matching = try await store.repository.save(matching, enqueue: false)
        var different = NoteRecord(title: "프로젝트 기록", notebookID: "work", markdown: "검토 내용")
        different.tags = ["개인"]
        _ = try await store.repository.save(different, enqueue: false)
        await store.load()
        store.advancedTitle = "프로젝트"
        store.advancedTag = "업무"
        store.advancedNotebookID = "work"
        await store.saveCurrentSearch(name: "업무 검색")
        let saved = try #require(store.savedSearches.first)
        store.resetAdvancedFilters()
        #expect(store.filtered(.smart(saved.id)).map(\.id) == [matching.id])
        let reopened = try LibraryStore(root: root, profile: firstProfile, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await reopened.load()
        #expect(reopened.filtered(.smart(saved.id)).map(\.id) == [matching.id])
        let second = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://nas.example", username: "second"), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await second.load()
        #expect(second.savedSearches.isEmpty)
    }

    @Test func clickingNoteLinkEmitsTargetSelection() async throws {
        final class Selected: @unchecked Sendable { var id: UUID? }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile())
        let source = try await store.repository.save(NoteRecord(title: "출발", markdown: "[다음](다음.md)"), enqueue: false)
        let target = try await store.repository.save(NoteRecord(title: "다음"), enqueue: false)
        await store.load()
        let selected = Selected()
        let observer = NotificationCenter.default.addObserver(forName: .openNote, object: nil, queue: nil) { notification in
            selected.id = notification.object as? UUID
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await store.openLinkedNote("다음.md", from: source.id)
        #expect(selected.id == target.id)
    }
}
