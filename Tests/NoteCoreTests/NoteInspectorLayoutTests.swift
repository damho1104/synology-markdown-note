import AppKit
import SwiftUI
import Testing
import NoteCore
@testable import SynologyNote

@Suite(.serialized) @MainActor struct NoteInspectorLayoutTests {
    @Test func inspectorFitsItsAllocatedWidthBeforeAndAfterExpansion() async throws {
        let previewRoot = ProcessInfo.processInfo.environment["SYNOLOGY_INSPECTOR_PREVIEW_DATA"]
        let root = previewRoot.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "inspector-layout-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            if previewRoot == nil { try? FileManager.default.removeItem(at: root) }
            preferences.removePersistentDomain(forName: suite)
        }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(), preferences: preferences)
        var note = NoteRecord(title: "레이아웃 검사", markdown: "테스트")
        note.remoteID = "remote-note-id-with-long-suffix"
        note.serverVersion = String(repeating: "a", count: 40)
        note.tags = [String(repeating: "긴태그", count: 20)]
        note.attachments = [try await store.attachments.importData(Data("test attachment".utf8), name: String(repeating: "긴첨부파일명", count: 12) + ".txt")]
        note = try await store.repository.save(note, enqueue: false)
        for index in 1...3 {
            _ = try await store.repository.save(NoteRecord(title: "\(index) " + String(repeating: "긴 참조 문서 이름 ", count: 5), markdown: "[참조](<레이아웃 검사.md>)"), enqueue: false)
        }
        try await store.reload()
        await store.loadBacklinks(for: note.id)
        #expect(store.backlinks[note.id]?.count == 3)
        let session = EditorSession(note: note)
        let host = NSHostingController(rootView: NoteInspector(session: session).environment(store))
        for width: CGFloat in [260, 300, 360, 520, 260] {
            let size = host.sizeThatFits(in: NSSize(width: width, height: 900))
            print("Inspector proposed \(width), measured \(size.width)")
            #expect(size.width <= width + 1)
        }
    }
}
