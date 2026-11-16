import Foundation
import Testing
@testable import SynologyNote
import NoteCore

@Suite @MainActor struct GlobalNoteSearchTests {
    private func store(at root: URL) throws -> LibraryStore {
        try LibraryStore(root: root, profile: ConnectionProfile(), preferences: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test func globalSearchIgnoresListAndAdvancedFiltersWithoutChangingThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try store(at: root)
        let note = try await library.repository.save(NoteRecord(title: "다른 메모장 보고서", notebookID: "other"), enqueue: false)
        await library.load()
        library.search = "목록 검색"
        library.fullTextMatches = [UUID()]
        library.advancedTitle = "불일치"
        library.advancedTag = "업무"
        library.advancedNotebookID = "current"
        library.advancedAfter = Date(timeIntervalSince1970: 100)
        library.advancedBefore = Date(timeIntervalSince1970: 200)
        let oldMatches = library.fullTextMatches
        #expect(library.filtered(.notebook("current")).isEmpty)
        let rows = try await library.globalSearch(query: "보고서")
        #expect(rows.map(\.id) == [note.id])
        #expect(library.search == "목록 검색")
        #expect(library.fullTextMatches == oldMatches)
        #expect(library.advancedTitle == "불일치")
        #expect(library.advancedTag == "업무")
        #expect(library.advancedNotebookID == "current")
        #expect(library.advancedAfter == Date(timeIntervalSince1970: 100))
        #expect(library.advancedBefore == Date(timeIntervalSince1970: 200))
        #expect(try await library.repository.pendingOperations().isEmpty)
    }

    @Test func findsTitleExcerptTagsAndCachedBodyButExcludesTrash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try store(at: root)
        let title = NoteRecord(title: "CaseNeedle")
        var excerpt = NoteRecord(title: "미리보기만", markdown: "미리보기 검색어")
        var tag = NoteRecord(title: "태그만"); tag.tags = ["태그검색어"]
        let body = NoteRecord(title: "긴 본문", markdown: String(repeating: "앞부분 ", count: 60) + "본문검색어")
        var trash = NoteRecord(title: "휴지통", markdown: "본문검색어"); trash.isTrashed = true
        _ = try await library.repository.save(title, enqueue: false)
        _ = try await library.repository.save(tag, enqueue: false)
        _ = try await library.repository.save(body, enqueue: false)
        _ = try await library.repository.save(trash, enqueue: false)
        await library.load()
        // NAS summaries may have an excerpt even before their body is cached.
        excerpt.hasRemoteContent = false
        library.summaries.append(excerpt.summary)
        #expect(try await library.globalSearch(query: "  caseneedle\n").map(\.id) == [title.id])
        #expect(try await library.globalSearch(query: "미리보기 검색어").map(\.id) == [excerpt.id])
        #expect(try await library.globalSearch(query: "태그검색어").map(\.id) == [tag.id])
        #expect(!body.summary.excerpt.contains("본문검색어"))
        #expect(try await library.globalSearch(query: "본문검색어").map(\.id) == [body.id])
        #expect(try await library.globalSearch(query: "일치없음").isEmpty)
    }

    @Test func blankQueryListsAllActiveNotesInStableModificationOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try store(at: root)
        var older = NoteRecord(title: "오래된 노트"); older.modifiedAt = Date(timeIntervalSince1970: 10)
        var newer = NoteRecord(title: "새 노트"); newer.modifiedAt = Date(timeIntervalSince1970: 20)
        var trash = NoteRecord(title: "휴지통"); trash.isTrashed = true
        library.summaries = [older.summary, trash.summary, newer.summary]
        #expect(try await library.globalSearch(query: "").map(\.id) == [newer.id, older.id])
        #expect(try await library.globalSearch(query: " \n\t ").map(\.id) == [newer.id, older.id])
    }

    @Test func cancelledSearchDoesNotReturnSelectableResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try store(at: root)
        library.summaries = [NoteRecord(title: "대상").summary]
        let task = Task { try await library.globalSearch(query: "대상") }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("취소된 검색이 결과를 반환했습니다")
        } catch is CancellationError {}
    }

    @Test func bodyDownloadInvalidatesSearchEvenWhenSummariesDoNotChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try store(at: root)
        var remote = NoteRecord(title: "원본 HTML 노트", notebookID: "book", mode: .original)
        remote.remoteID = "remote-html"
        remote.serverVersion = "v1"
        remote.originalHTML = "<p>이전 본문</p>"
        _ = try await library.repository.mergeRemote(remote)
        remote.serverVersion = "v2"
        remote.modifiedAt = remote.modifiedAt.addingTimeInterval(10)
        remote.originalHTML = "<p>새본문검색어</p>"
        // The NAS list updates metadata before the new body is downloaded.
        try await library.repository.observeRemote(remote)
        try await library.reload()
        let previousSummaries = library.summaries
        let previousRequest = GlobalNoteSearchRequest(query: "새본문검색어", library: library)
        #expect(try await library.globalSearch(query: "새본문검색어").isEmpty)
        _ = try await library.repository.mergeRemote(remote)
        try await library.reload()
        #expect(library.summaries == previousSummaries)
        #expect(GlobalNoteSearchRequest(query: "새본문검색어", library: library) != previousRequest)
        #expect(try await library.globalSearch(query: "새본문검색어").map(\.id) == previousSummaries.map(\.id))
    }
}
