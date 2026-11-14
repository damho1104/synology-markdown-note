import Foundation
import Testing
@testable import NoteCore
@testable import SynologyNote

@Suite struct InternalNoteLinkTests {
    private func repository() throws -> (NoteRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try NoteRepository(directory: directory), directory)
    }

    @Test func markdownExtractionIgnoresCodeAndPreviewKeepsReadableSource() {
        let markdown = """
        [대상](<대상 문서.md>)

        `\u{005B}코드](코드.md)`

        ```md
        [코드 블록](코드.md)
        ```

        [웹](https://example.com/page.md)
        """
        #expect(InternalNoteLinks.destinations(in: markdown) == ["대상 문서.md"])
        #expect(InternalNoteLinks.title(for: "대상%20문서.md") == "대상 문서")
        #expect(InternalNoteLinks.title(for: "../대상.md") == nil)
        let html = MarkdownPipeline.renderForPreview(markdown, blocks: [])
        let preview = InternalNoteLinks.previewHTML(html)
        #expect(preview.contains("synology-note://link?destination="))
        #expect(preview.contains("https://example.com/page.md"))
        #expect(markdown.contains("[대상](<대상 문서.md>)"))
    }

    @Test func openAndBacklinkSurviveRenameRestartAndEdits() async throws {
        let (repo, dir) = try repository()
        defer { try? FileManager.default.removeItem(at: dir) }
        var source = try await repo.save(NoteRecord(title: "출발", markdown: "[대상](<옛 제목.md>)"), enqueue: false)
        var target = try await repo.save(NoteRecord(title: "옛 제목", markdown: "기존 본문"), enqueue: false)
        #expect(try await repo.backlinks(to: target.id).map(\.id) == [source.id])
        // The link has never been clicked. Renaming still preserves its target.
        target.title = "새 제목"
        target = try await repo.save(target, enqueue: false)
        #expect(try await repo.resolveLink("옛 제목.md", from: source.id) == target.id)
        let reopened = try NoteRepository(directory: dir)
        #expect(try await reopened.resolveLink("옛 제목.md", from: source.id) == target.id)
        #expect(try await reopened.backlinks(to: target.id).map(\.id) == [source.id])
        #expect(try await reopened.note(id: source.id)?.markdown == "[대상](<옛 제목.md>)")
        source.markdown = "링크 삭제"
        _ = try await reopened.save(source, enqueue: false)
        #expect(try await reopened.backlinks(to: target.id).isEmpty)
    }

    @Test func duplicateTitlesMustNotOpenArbitraryNote() async throws {
        let (repo, dir) = try repository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await repo.save(NoteRecord(title: "출발", markdown: "[보기](같은.md)"), enqueue: false)
        _ = try await repo.save(NoteRecord(title: "같은"), enqueue: false)
        _ = try await repo.save(NoteRecord(title: "같은"), enqueue: false)
        await #expect(throws: RepositoryError.self) { try await repo.resolveLink("같은.md", from: source.id) }
    }

    @Test func savedSearchAndLiteralIndexSurviveRestart() async throws {
        let (repo, dir) = try repository()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await repo.save(NoteRecord(title: "첫 번째", markdown: "찾는말 100%_literal \"인용\""), enqueue: false)
        let second = try await repo.save(NoteRecord(title: "두 번째", markdown: "찾는말 많이"), enqueue: false)
        let search = SavedSearch(name: "작업용", query: "찾는말", tag: "업무")
        try await repo.saveSearch(search)
        let reopened = try NoteRepository(directory: dir)
        #expect(try await reopened.searchNoteIDs("찾는말") == [first.id, second.id])
        #expect(try await reopened.searchNoteIDs("%_literal") == [first.id])
        #expect(try await reopened.searchNoteIDs("\"인용\"") == [first.id])
        #expect(try await reopened.savedSearches() == [search])
        try await reopened.deleteSearch(id: search.id)
        #expect(try await reopened.savedSearches().isEmpty)
    }

    @Test func managedConnectionsPreserveUserSectionsAndRepeatedBodyLinks() {
        let target = NoteRecord(title: "제목 [특수] (한글) 🔗").summary
        let destination = InternalNoteLinks.destination(for: target)
        let body = """
        # 문서
        ## 관련 노트 (앱에서 관리)
        사용자가 직접 쓴 내용

        \(InternalNoteLinks.link("원문 표시", target: target))
        \(InternalNoteLinks.link("다른 본문 참조", target: target))
        """
        guard let added = InternalNoteLinks.addManagedLink(body, target: target) else {
            Issue.record("관리 영역 생성 실패"); return
        }
        #expect(added.contains(body))
        #expect(InternalNoteLinks.managedDestinations(in: added) == [destination])
        #expect(InternalNoteLinks.destinations(in: added) == [destination])
        #expect(InternalNoteLinks.addManagedLink(added, target: target) == added)
        guard let removed = InternalNoteLinks.removeManagedLink(added, target: target) else {
            Issue.record("관리 영역 제거 실패"); return
        }
        #expect(removed.contains(body))
        #expect(InternalNoteLinks.managedDestinations(in: removed).isEmpty)
        #expect(InternalNoteLinks.destinations(in: removed) == [destination])
        #expect(removed.contains("사용자가 직접 쓴 내용"))
        let invalid = added + "\n" + InternalNoteLinks.managedStart
        #expect(InternalNoteLinks.addManagedLink(invalid, target: target) == nil)
        #expect(InternalNoteLinks.removeManagedLink(invalid, target: target) == nil)
    }

    @Test func completionRespectsUnicodeCodeAndCaretPosition() {
        func atEnd(_ text: String) -> InternalNoteLinks.Completion? {
            InternalNoteLinks.completion(in: text, caret: text.utf16.count)
        }
        let prompt = "🌟 한글 [[검색어"
        #expect(atEnd(prompt)?.query == "검색어")
        #expect(atEnd(prompt)?.range == NSRange(location: "🌟 한글 ".utf16.count, length: "[[검색어".utf16.count))
        #expect(atEnd("```swift\n[[코드") == nil)
        #expect(atEnd("~~~swift\n[[코드") == nil)
        #expect(atEnd("`코드 [[검색") == nil)
        #expect(atEnd("``코드 [[검색") == nil)
        #expect(atEnd("`코드` [[검색")?.query == "검색")
        #expect(atEnd("``코드`` [[검색")?.query == "검색")
        #expect(atEnd("```swift\n[[코드\n```\n[[가능")?.query == "가능")
        #expect(atEnd("[[찾기]]") == nil)
        #expect(InternalNoteLinks.completion(in: "[[찾기", caret: 1) == nil)
        #expect(InternalNoteLinks.completion(in: "[[한글검색", caret: "[[한글".utf16.count) == nil)
        #expect(InternalNoteLinks.completion(in: "[[한글검색\n다음 줄", caret: "[[한글검색".utf16.count)?.query == "한글검색")
    }

    @Test func stableIdentitiesHandleDuplicateTitlesRenamesAndNASIDs() async throws {
        let (repo, dir) = try repository()
        defer { try? FileManager.default.removeItem(at: dir) }
        var remote = NoteRecord(title: "중복 [제목]")
        remote.remoteID = "NAS:한글 % ? /"
        remote = try await repo.save(remote, enqueue: false)
        let local = try await repo.save(NoteRecord(title: "중복 [제목]"), enqueue: false)
        let firstDestination = InternalNoteLinks.destination(for: remote.summary)
        let secondDestination = InternalNoteLinks.destination(for: local.summary)
        #expect(firstDestination != secondDestination)
        #expect(InternalNoteLinks.remoteID(for: firstDestination) == remote.remoteID)
        var source = try await repo.save(NoteRecord(title: "출발", markdown:
            InternalNoteLinks.link("원격", target: remote.summary) + "\n" +
            InternalNoteLinks.link("로컬", target: local.summary)), enqueue: false)
        #expect(try await repo.resolveLink(firstDestination, from: source.id) == remote.id)
        #expect(try await repo.resolveLink(secondDestination, from: source.id) == local.id)
        await #expect(throws: RepositoryError.self) { try await repo.resolveLink("중복 [제목].md", from: source.id) }
        remote.title = "이름 변경"
        remote = try await repo.save(remote, enqueue: false)
        let reopened = try NoteRepository(directory: dir)
        #expect(try await reopened.resolveLink(firstDestination, from: source.id) == remote.id)
        #expect(Set(try await reopened.noteGraph().connections(of: source.id).outgoing.map(\.id)) == [remote.id, local.id])
        #expect(try await reopened.backlinks(to: remote.id).map(\.id) == [source.id])
        source.markdown = "일반 텍스트"
        _ = try await reopened.save(source, enqueue: false)
        #expect(try await reopened.noteGraph().connections(of: source.id).outgoing.isEmpty)
        #expect(try await reopened.backlinks(to: remote.id).isEmpty)
    }

    @Test func localIdentityAliasSurvivesNASImportAndRestart() async throws {
        let (repo, dir) = try repository()
        defer { try? FileManager.default.removeItem(at: dir) }
        var target = try await repo.save(NoteRecord(title: "처음 이름"), enqueue: false)
        let original = InternalNoteLinks.destination(for: target.summary)
        let source = try await repo.save(NoteRecord(title: "출발", markdown:
            InternalNoteLinks.link("원래 연결", target: target.summary)), enqueue: false)

        // A remote source envelope can provide a different document identity
        // after the local cache identity was already used in Markdown links.
        target.sourceDocumentID = UUID()
        target.title = "NAS에서 바꾼 이름"
        _ = try await repo.save(target, enqueue: false)
        let newDestination = InternalNoteLinks.destination(for: target.summary)
        #expect(original != newDestination)

        let reopened = try NoteRepository(directory: dir)
        #expect(try await reopened.resolveLink(original, from: source.id) == target.id)
        #expect(try await reopened.resolveLink(newDestination, from: source.id) == target.id)
        #expect(try await reopened.backlinks(to: target.id).map(\.id) == [source.id])
        #expect(try await reopened.noteGraph().connections(of: source.id).outgoing.map(\.id) == [target.id])

        // Never resolve the same UUID alias to an arbitrary note on collision.
        var duplicate = NoteRecord(title: "다른 노트")
        duplicate.sourceDocumentID = target.id
        _ = try await reopened.save(duplicate, enqueue: false)
        await #expect(throws: RepositoryError.self) {
            try await reopened.resolveLink(original, from: source.id)
        }
        #expect(try await reopened.noteGraph().connections(of: source.id).outgoing.isEmpty)
    }

    @Test func sourceEnvelopeAndOldSummaryRemainReadable() throws {
        var note = NoteRecord(title: "복원 대상")
        note.sourceDocumentID = UUID()
        let originalLink = InternalNoteLinks.link("선택한 문구", target: note.summary)
        let markdown = "기존 [링크](<옛 노트.md>)\n" + originalLink
        let envelope = SourceEnvelope(documentID: note.sourceDocumentID!, markdown: markdown, blocks: [], html: "<p>test</p>")
        let decoded = try SourceEnvelope.decode(envelope.encoded())
        #expect(decoded.documentID == note.sourceDocumentID)
        #expect(decoded.markdown == markdown)
        #expect(InternalNoteLinks.destinations(in: decoded.markdown) == ["옛 노트.md", InternalNoteLinks.destination(for: note.summary)])
        let summaryData = try JSONEncoder().encode(note.summary)
        var json = try #require(JSONSerialization.jsonObject(with: summaryData) as? [String: Any])
        json.removeValue(forKey: "sourceDocumentID")
        let oldSummary = try JSONDecoder().decode(NoteSummary.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(oldSummary.sourceDocumentID == nil)
        #expect(oldSummary.id == note.id)
    }
}
