import Foundation
import Testing
import NoteCore
@testable import SynologyNote

@Suite @MainActor struct LibraryManagementTests {
    @Test func referencedFileCannotBeRemovedFromMarkdownOrActivePreservedBlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile())
        let asset = try await store.attachments.importData(Data([1]), name: "image.png")
        var note = NoteRecord(markdown: "![image](\(asset.reference))")
        note.attachments = [asset]
        let saved = try await store.repository.save(note, enqueue: false)
        let session = try #require(await store.session(for: saved.id))
        await store.removeAttachment(asset, from: session)
        #expect(session.note.attachments == [asset])
        #expect(store.errorMessage != nil)
        let block = PreservedBlock(id: "opaque", html: "<div><img content_id='\(asset.id.uuidString)'></div>", label: "보존")
        session.note.blocks = [block]; session.note.markdown = MarkdownPipeline.token(for: block)
        store.errorMessage = nil
        await store.removeAttachment(asset, from: session)
        #expect(session.note.attachments == [asset])
        #expect(session.note.blocks == [block])
        #expect(store.errorMessage != nil)
    }
    @Test func unreferencedRemovalPreservesOtherBlocksHistoryAndPhysicalFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile())
        let asset = try await store.attachments.importData(Data([1, 2]), name: "image.png")
        let block = PreservedBlock(id: "other", html: "<div>복잡한 서식 보존</div>", label: "보존")
        var note = NoteRecord(markdown: "문단\n" + MarkdownPipeline.token(for: block))
        note.blocks = [block]; note.attachments = [asset]
        let saved = try await store.repository.save(note, enqueue: false)
        let session = try #require(await store.session(for: saved.id))
        await store.removeAttachment(asset, from: session)
        #expect(session.note.attachments.isEmpty)
        #expect(session.note.markdown == note.markdown && session.note.blocks == [block])
        #expect(try await store.attachments.verifiedData(for: asset) == Data([1, 2]))
        #expect(try await store.repository.revisions(noteID: saved.id).contains { $0.note.attachments == [asset] })
    }
    @Test func legacyNotebookCannotBeRenamedAsLocalOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile())
        try await store.repository.setNotebooks([Notebook(id: "local-book", name: "before")]); try await store.reload()
        await #expect(throws: RepositoryError.self) { try await store.renameNotebook(id: "local-book", name: " after ") }
        #expect(try await store.repository.notebooks().first?.name == "before")
        #expect(!store.isConnected)
    }
}
