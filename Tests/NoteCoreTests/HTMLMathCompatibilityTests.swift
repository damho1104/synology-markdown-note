import Foundation
import Testing
import SwiftSoup
@testable import NoteCore
@testable import SynologyNote

@Suite struct HTMLMathCompatibilityTests {
    @Test func serverRenderingPreservesTeXDelimitersAndLineBreaks() throws {
        let source = #"인라인 \(\frac{a_1}{b_2}\) 와 $$\begin{aligned}a &= b \\ c &= d\end{aligned}$$"#
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.render(source))
        #expect(try dom.select("p").text() == source)
        #expect(try dom.select("em").isEmpty())
    }

    @Test func importingHTMLDoesNotAddEscapesInsideRecognizedFormulas() throws {
        let source = #"인라인 $\frac{a_1}{b_2}$ 와 \(x_1 + y_2\)"#
        let imported = MarkdownPipeline.importHTML("<p>" + source + "</p>")
        #expect(imported.markdown == source)
        let preview = try SwiftSoup.parseBodyFragment(MarkdownPipeline.renderForPreview(imported.markdown))
        #expect(try preview.select(".note-math").first()?.text() == #"\frac{a_1}{b_2}"#)
    }

    @Test func repeatedHTMLRoundTripKeepsFormulaAndCodeBackslashes() throws {
        var source = #"""
        $$\begin{aligned}a &= b \\ c &= d\end{aligned}$$

        ```swift
        let path = #"C:\temp\notes"#
        let regex = #"\d+\\value"#
        ```
        """#
        let original = source
        for _ in 0..<4 {
            source = MarkdownPipeline.importHTML(MarkdownPipeline.render(source)).markdown
            #expect(source == original)
        }
    }

    @Test func originalBodyEditSurvivesLocalSaveAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try NoteRepository(directory: directory)
        var note = NoteRecord(title: "서식", notebookID: "book", mode: .original)
        note.remoteID = "remote"; note.serverVersion = "v1"; note.baseHTML = "<p>기존</p>"
        note.originalHTML = "<p>기존</p>"
        note = try await repo.save(note, enqueue: false)
        note.originalHTML = "<p style=\"color:red\">수정한 <strong>본문</strong></p>"
        let saved = try await repo.save(note)
        #expect(saved.originalHTML == note.originalHTML)
        #expect(saved.baseHTML == "<p>기존</p>")
        let reopened = try NoteRepository(directory: directory)
        #expect(try await reopened.note(id: note.id)?.originalHTML == note.originalHTML)
    }

    @Test func completedUploadCannotReplaceNewerHTMLDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try NoteRepository(directory: directory)
        var note = NoteRecord(title: "서식", notebookID: "book", mode: .original)
        note.remoteID = "remote"; note.serverVersion = "v1"; note.baseHTML = "<p>기존</p>"; note.originalHTML = "<p>전송 내용</p>"
        note = try await repo.save(note)
        let operation = try #require(try await repo.pendingOperations().first)
        let attempt = SyncAttempt(operation: operation, note: note, html: note.originalHTML, source: Data())
        try await repo.beginSync(attempt)
        note.originalHTML = "<p>계속 편집한 내용</p>"
        _ = try await repo.save(note)
        try await repo.completeSync(attempt, snapshot: SyncRemoteSnapshot(remoteID: "remote", version: "v2", html: "<p>전송 내용</p>", source: nil))
        let saved = try #require(try await repo.note(id: note.id))
        #expect(saved.originalHTML == "<p>계속 편집한 내용</p>")
        #expect(saved.baseHTML == "<p>전송 내용</p>")
        #expect(saved.syncState == .pending)
    }

    @Test func undoBackToServerBaselineIsPersistedAsARealHTMLEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try NoteRepository(directory: directory)
        var note = NoteRecord(title: "되돌리기", notebookID: "book", mode: .original)
        note.remoteID = "remote"; note.serverVersion = "v1"; note.baseHTML = "<p>A</p>"; note.originalHTML = "<p>A</p>"
        note = try await repo.save(note, enqueue: false)
        note.originalHTML = "<p>B</p>"; note = try await repo.save(note)
        note.originalHTML = "<p>A</p>"
        let saved = try await repo.save(note)
        #expect(saved.originalHTML == "<p>A</p>")
        #expect(saved.syncState == .pending)
    }

    @Test @MainActor func uploadCompletionCannotReplaceAnUnsavedUndoToBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try LibraryStore(root: directory, profile: ConnectionProfile())
        var note = NoteRecord(mode: .original)
        note.originalHTML = "<p>A</p>"; note.baseHTML = "<p>A</p>"; note.revision = 1
        let session = EditorSession(note: note)
        session.editGeneration = 2; session.savedGeneration = 1
        var uploaded = note
        uploaded.originalHTML = "<p>B</p>"; uploaded.baseHTML = "<p>B</p>"; uploaded.serverVersion = "v2"
        library.integrateUploadedRecord(uploaded, into: session, expectedEditGeneration: 1, expectedSavedGeneration: 1)
        #expect(session.note.originalHTML == "<p>A</p>")
        #expect(session.note.baseHTML == "<p>B</p>")
        #expect(session.note.serverVersion == "v2")
    }

    @Test func attachmentBindingComparisonRejectsOtherBodyChanges() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let asset = NoteAttachment(id: id, name: "image.png", filename: "image.png", sha256: "hash", byteCount: 0)
        var remote = asset; remote.remoteID = "server-file"; remote.remoteReference = id.uuidString
        let local = "<p>본문<img src=\"attachment://\(id)\" alt=\"이미지\"></p>"
        let server = "<p>본문<img ref=\"\(id)\" alt=\"이미지\"></p>"
        #expect(HTMLAttachmentComparison.matches(local, server, expectedAssets: [asset], actualAssets: [remote]))
        #expect(!HTMLAttachmentComparison.matches(local, server.replacingOccurrences(of: "본문", with: "다른 본문"), expectedAssets: [asset], actualAssets: [remote]))
        #expect(!HTMLAttachmentComparison.matches(local, server.replacingOccurrences(of: "이미지", with: "다른 이미지"), expectedAssets: [asset], actualAssets: [remote]))
    }

    @Test func originalHTMLAttachmentRemovalRequiresRemovingTheReferenceFirst() throws {
        let asset = NoteAttachment(name: "file.txt", filename: "file.txt", sha256: "hash", byteCount: 0, remoteID: "remote-file")
        var note = NoteRecord(mode: .original)
        note.attachments = [asset]; note.originalHTML = "<p>첨부를 사용하지 않는 본문</p>"
        #expect(try AttachmentManagement.removing(asset, from: note).attachments.isEmpty)
        note.originalHTML = "<a ref=\"remote-file\">파일</a>"
        #expect(throws: RepositoryError.self) { try AttachmentManagement.removing(asset, from: note) }
    }

    @Test func attachmentTagScannerSkipsLiteralTagsAndQuotedClosingCharacters() throws {
        let html = #"<!--<img src='literal'>--><script>const s='<img src=x>';</script><style>x::before{content:'<a href=x>'}</style><p>한글 <img src='attachment://first' alt='a > b'><a href='attachment://second'>내용</a></p>"#
        let slices = HTMLSourcePatcher.attachmentTags(in: html)
        #expect(slices.map(\.html) == ["<img src='attachment://first' alt='a > b'>", "<a href='attachment://second'>"])
        let patched = try HTMLSourcePatcher.replacing(in: html, replacements: [(slices[0].range, "<img ref='file'>")])
        #expect(patched == #"<!--<img src='literal'>--><script>const s='<img src=x>';</script><style>x::before{content:'<a href=x>'}</style><p>한글 <img ref='file'><a href='attachment://second'>내용</a></p>"#)
    }

    @Test func mathMetadataEnvelopeRebindsGeneratedImagesAndRejectsInvalidDimensions() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let formula = MathFormula(tex: #"\frac{a}{b}"#, display: false)
        let metadata = MathAttachmentMetadata(key: formula.key, width: 42, height: 24)
        let source = SourceEnvelope(documentID: UUID(), markdown: #"$\frac{a}{b}$"#, blocks: [], html: "<p>body</p>",
            operationID: UUID(), attachmentBindings: [id.uuidString: "file"], mathAttachments: [id.uuidString: metadata])
        let decoded = try SourceEnvelope.decode(source.encoded())
        let asset = NoteAttachment(name: "math.png", filename: "math.png", sha256: "hash", byteCount: 0, remoteID: "file")
        let restored = try decoded.restoredAttachments(from: [asset])
        #expect(restored.first?.id == id)
        #expect(restored.first?.generatedMath == metadata)
        #expect(decoded.markdown == #"$\frac{a}{b}$"#)
        let invalid = SourceEnvelope(documentID: UUID(), markdown: "$x$", blocks: [], html: "body", mathAttachments: [id.uuidString: MathAttachmentMetadata(key: formula.key, width: .nan, height: 20)])
        #expect(throws: SourceEnvelopeError.self) { try SourceEnvelope.decode(invalid.encoded()) }
    }
}
