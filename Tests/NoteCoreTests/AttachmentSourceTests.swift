import Foundation
import Testing
import SwiftSoup
@testable import NoteCore

@Suite struct AttachmentSourceTests {
    @Test func sourceRebindsFreshLocalIDsWithoutChangingMarkdownBytes() throws {
        let id = UUID()
        let markdown = "---\r\ncover: attachment://literal\r\n---\r\n\r\n```md\r\n![literal](attachment://example)\r\n```\r\n\r\n![한글](attachment://\(id))\r\n"
        let source = SourceEnvelope(documentID: UUID(), markdown: markdown, blocks: [], html: "<p>body</p>")
        let decoded = try SourceEnvelope.decode(source.encoded())
        let asset = NoteAttachment(name: "image.png", filename: "copied.png", sha256: "synthetic", byteCount: 1, remoteID: "file-1", remoteReference: id.uuidString)
        let restored = try decoded.restoredAttachments(from: [asset])
        #expect(restored[0].id == id)
        #expect(restored[0].filename == asset.filename)
        #expect(Data(decoded.markdown.utf8) == Data(markdown.utf8))
    }

    @Test func missingAndAmbiguousRefsCannotRestoreSource() throws {
        let id = UUID()
        let source = SourceEnvelope(documentID: UUID(), markdown: "![image](attachment://\(id))", blocks: [], html: "body")
        #expect(throws: SourceEnvelopeError.self) { try source.restoredAttachments(from: []) }
        let first = NoteAttachment(name: "a.png", filename: "a", sha256: "hash", byteCount: 0, remoteReference: id.uuidString)
        let second = NoteAttachment(name: "b.png", filename: "b", sha256: "hash", byteCount: 0, remoteReference: id.uuidString)
        #expect(throws: SourceEnvelopeError.self) { try source.restoredAttachments(from: [first, second]) }
    }

    @Test func previewResolvesServerRefToLocallyVerifiedAsset() throws {
        let asset = NoteAttachment(name: "image.png", filename: "a", sha256: "hash", byteCount: 1, remoteReference: "server-ref")
        let safe = AttachmentResolver.previewHTML("<p><img ref='server-ref' alt='image'></p>", attachments: [asset])
        #expect(try SwiftSoup.parseBodyFragment(safe).select("img").attr("src") == asset.reference)
    }

    @Test func multipartRejectsMissingFilesAndHeaderInjectionBeforeSending() throws {
        #expect(throws: NoteStationError.self) { try NoteStationMultipart.encode(urlEncodedFields: Data(), files: [], boundary: "boundary") }
        #expect(throws: NoteStationError.self) {
            try NoteStationMultipart.encode(urlEncodedFields: Data("object_id=synthetic".utf8), files: [
                .init(partName: "file", filename: "bad\r\nname", mimeType: "image/png", data: Data([1]))
            ], boundary: "boundary")
        }
    }
}
