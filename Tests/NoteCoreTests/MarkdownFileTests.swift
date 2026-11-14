import Foundation
import Testing
@testable import NoteCore

@Suite struct MarkdownFileTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        return root
    }

    @Test func importCopiesRelativeAssetAndExportKeepsUsableReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let image = root.appendingPathComponent("assets/사진.png")
        try Data([1,2,3]).write(to: image)
        let source = root.appendingPathComponent("문서.md")
        try "# 제목\n\n![사진](assets/사진.png)".write(to: source, atomically: true, encoding: .utf8)
        let store = try AttachmentStore(directory: root.appendingPathComponent("managed"))
        let imported = try await MarkdownFiles.importFile(source, store: store)
        #expect(imported.attachments.count == 1)
        #expect(imported.markdown.contains("attachment://"))
        try FileManager.default.removeItem(at: image)
        let output = root.appendingPathComponent("export/문서.md")
        try await MarkdownFiles.export(imported, to: output, store: store)
        let exported = try String(contentsOf: output, encoding: .utf8)
        #expect(exported.contains("assets/"))
        #expect(!exported.contains("attachment://"))
        #expect(FileManager.default.fileExists(atPath: output.deletingLastPathComponent().appendingPathComponent("assets/" + imported.attachments[0].filename).path))
    }
    @Test func importRejectsAssetOutsideSelectedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("selected"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("private.png"))
        let source = root.appendingPathComponent("selected/test.md")
        try "![x](../private.png)".write(to: source, atomically: true, encoding: .utf8)
        let store = try AttachmentStore(directory: root.appendingPathComponent("managed"))
        await #expect(throws: MarkdownFileError.self) { try await MarkdownFiles.importFile(source, store: store) }
    }

    @Test func importRewritesOnlyASTDestinationsAndRetainsExactUTF8Source() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2]).write(to: root.appendingPathComponent("assets/사진.png"))
        let source = root.appendingPathComponent("문서.md")
        let prefix = "---\r\ncover: ![메타](assets/사진.png)\r\n---\r\n\r\n```md\r\n![코드](assets/사진.png)\r\n(assets/사진.png)\r\n```\r\n\r\n문장 (assets/사진.png) `![인라인](assets/사진.png)`\r\n\r\n한글 🐱 "
        let text = prefix + "![사진](assets/사진.png \"제목\") [파일](assets/사진.png '링크 제목')\r\n"
        try Data(text.utf8).write(to: source)
        let store = try AttachmentStore(directory: root.appendingPathComponent("managed"))
        let note = try await MarkdownFiles.importFile(source, store: store)
        let reference = try #require(note.attachments.first?.reference)
        #expect(note.attachments.count == 1)
        let expected = prefix + "![사진](\(reference) \"제목\") [파일](\(reference) '링크 제목')\r\n"
        #expect(Data(note.markdown.utf8) == Data(expected.utf8))
    }

    @Test func importCopiesRepeatedPercentEscapedAssetOnlyOnce() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([3, 4]).write(to: root.appendingPathComponent("assets/한글 사진.png"))
        let source = root.appendingPathComponent("문서.md")
        try "🐱 ![첫째](assets/한글%20사진.png \"제목\") ![둘째](<assets/한글 사진.png>) [셋째](assets/한글%20사진.png)".write(to: source, atomically: true, encoding: .utf8)
        let store = try AttachmentStore(directory: root.appendingPathComponent("managed"))
        let note = try await MarkdownFiles.importFile(source, store: store)
        #expect(note.attachments.count == 1)
        let reference = try #require(note.attachments.first?.reference)
        #expect(note.markdown == "🐱 ![첫째](\(reference) \"제목\") ![둘째](<\(reference)>) [셋째](\(reference))")
    }

    @Test func importRewritesOnlyActiveReferenceDefinitions() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([5]).write(to: root.appendingPathComponent("assets/사진.png"))
        let source = root.appendingPathComponent("문서.md")
        let prefix = "```md\n[사진 키]: assets/사진.png \"코드\"\n```\n\n![사진][사진 키] [파일][사진 키]\n\n"
        let text = prefix + "[사진 키]: <assets/사진.png> \"실제 제목\"\n[사진 키]: assets/사진.png \"중복 정의\"\n"
        try text.write(to: source, atomically: true, encoding: .utf8)
        let store = try AttachmentStore(directory: root.appendingPathComponent("managed"))
        let note = try await MarkdownFiles.importFile(source, store: store)
        let reference = try #require(note.attachments.first?.reference)
        #expect(note.attachments.count == 1)
        #expect(note.markdown == prefix + "[사진 키]: <\(reference)> \"실제 제목\"\n[사진 키]: assets/사진.png \"중복 정의\"\n")
    }

    @Test func importLeavesNetworkURLsUntouchedWithoutFetching() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("문서.md")
        let text = "![원격](https://example.invalid/photo.png) ![상대](//example.invalid/photo.png) [메일](mailto:note@example.invalid)"
        try text.write(to: source, atomically: true, encoding: .utf8)
        let note = try await MarkdownFiles.importFile(source, store: AttachmentStore(directory: root.appendingPathComponent("managed")))
        #expect(note.attachments.isEmpty)
        #expect(note.markdown == text)
    }

    @Test func importRejectsEncodedTraversalAndSymlinkEscape() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("selected"), withIntermediateDirectories: true)
        try Data([8]).write(to: root.appendingPathComponent("private.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("selected/linked.png"), withDestinationURL: root.appendingPathComponent("private.png"))
        let source = root.appendingPathComponent("selected/문서.md")
        let store = try AttachmentStore(directory: root.appendingPathComponent("managed"))
        for path in ["%2e%2e/private.png", "linked.png", "/etc/passwd"] {
            try "![x](\(path))".write(to: source, atomically: true, encoding: .utf8)
            await #expect(throws: MarkdownFileError.self) { try await MarkdownFiles.importFile(source, store: store) }
        }
    }

    @Test func exportResolvesRemoteImagesInOriginalAndEachOpaqueBlock() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentStore(directory: root.appendingPathComponent("managed"))
        var attachment = try await store.importData(Data([9, 10]), name: "사진.png")
        attachment.remoteID = "remote-file"
        let raw = "<div data-widget='원본'><img ref='remote-file' src='https://nas.invalid/file?file_id=remote-file&amp;token=secret'></div>"
        var original = NoteRecord(title: "원본", mode: .original)
        original.originalHTML = raw
        original.attachments = [attachment]
        let originalURL = root.appendingPathComponent("export/original.html")
        try await MarkdownFiles.export(original, to: originalURL, store: store)
        let originalExport = try String(contentsOf: originalURL, encoding: .utf8)
        #expect(originalExport.contains("assets/" + attachment.filename))
        #expect(!originalExport.contains("https://nas.invalid"))
        #expect(original.originalHTML == raw)
        let block = PreservedBlock(id: "original", html: raw, label: "원본")
        var markdown = NoteRecord(title: "블록", markdown: "한글\n\n" + MarkdownPipeline.token(for: block))
        markdown.blocks = [block]
        markdown.attachments = [attachment]
        let markdownURL = root.appendingPathComponent("export/블록.md")
        try await MarkdownFiles.export(markdown, to: markdownURL, store: store)
        let blockExport = try String(contentsOf: markdownURL, encoding: .utf8)
        #expect(blockExport.hasPrefix("한글\n\n"))
        #expect(blockExport.contains("assets/" + attachment.filename))
        #expect(!blockExport.contains("https://nas.invalid"))
        #expect(markdown.blocks[0].html == raw)
        let sidecar = try Data(contentsOf: markdownURL.deletingPathExtension().appendingPathExtension("preserved.json"))
        #expect(try JSONDecoder().decode([PreservedBlock].self, from: sidecar) == [block])
    }

    @Test func exportNeverRewritesLiteralMarkdownOrFrontmatter() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentStore(directory: root.appendingPathComponent("managed"))
        let attachment = try await store.importData(Data([11]), name: "사진.png")
        let prefix = "---\r\ncover: ![메타](\(attachment.reference))\r\n---\r\n\r\n```md\r\n![코드](\(attachment.reference))\r\n```\r\n문장 \(attachment.reference)\r\n한글 🐱 "
        var note = NoteRecord(markdown: prefix + "![사진](\(attachment.reference) \"제목\")\r\n")
        note.attachments = [attachment]
        let output = root.appendingPathComponent("export/문서.md")
        try await MarkdownFiles.export(note, to: output, store: store)
        let expected = prefix + "![사진](assets/\(attachment.filename) \"제목\")\r\n"
        #expect(try Data(contentsOf: output) == Data(expected.utf8))
    }

    @Test func exportSidecarCollisionPreservesBothUnrelatedFileAndPayload() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentStore(directory: root.appendingPathComponent("managed"))
        let block = PreservedBlock(id: "table", html: "<table data-original='yes'></table>", label: "표")
        var note = NoteRecord(markdown: MarkdownPipeline.token(for: block))
        note.blocks = [block]
        let output = root.appendingPathComponent("문서.md")
        let collision = root.appendingPathComponent("문서.preserved.json")
        let unrelated = Data("다른 사용자의 파일".utf8)
        try unrelated.write(to: collision)
        try await MarkdownFiles.export(note, to: output, store: store)
        #expect(try Data(contentsOf: collision) == unrelated)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let collisionName = collision.lastPathComponent.precomposedStringWithCanonicalMapping
        let payloads = files.filter {
            $0.pathExtension == "json" && $0.lastPathComponent.precomposedStringWithCanonicalMapping != collisionName
        }
        #expect(payloads.count == 1)
        let preserved = try #require(payloads.first)
        #expect(try JSONDecoder().decode([PreservedBlock].self, from: Data(contentsOf: preserved)) == [block])
    }
}
