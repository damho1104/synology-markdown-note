import AppKit
import SwiftUI
import Testing
@testable import SynologyNote

@Suite(.serialized) @MainActor struct MarkdownEditorScrollTests {
    private struct EditorHost: View {
        @State var text: String
        let position: EditorPosition
        var body: some View {
            MarkdownEditor(text: $text, blocks: [], position: position,
                           undoManager: UndoManager(), isEditable: true,
                           onFiles: { _ in }, onImage: { _ in })
        }
    }

    @Test func editingLongScrolledDocumentKeepsCaretAndViewportStable() throws {
        let lines = (0..<240).map { index in
            index.isMultiple(of: 7) ? "## 제목 \(index) 와 **강조** 문장" : "내용 \(index) 와 테스트 문장을 편집합니다."
        }
        let text = lines.joined(separator: "\n")
        let position = EditorPosition()
        let hosting = NSHostingView(rootView: EditorHost(text: text, position: position))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let editor = try #require(position.editor)
        let clip = try #require(editor.enclosingScrollView?.contentView)
        window.makeFirstResponder(editor)
        let targetLine = lines[125]
        let range = (text as NSString).range(of: targetLine)
        #expect(range.location != NSNotFound)
        let insertion = NSRange(location: range.location + 3, length: 0)
        editor.setSelectedRange(insertion)
        editor.scrollRangeToVisible(insertion)
        window.displayIfNeeded()
        #expect(clip.bounds.origin.y > 0)
        let initialY = clip.bounds.origin.y
        let storage = try #require(editor.textStorage)
        var styledRanges: [NSRange] = []
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                             object: storage, queue: nil) { notification in
            guard let changed = notification.object as? NSTextStorage,
                  changed.editedMask.contains(.editedAttributes) else { return }
            styledRanges.append(changed.editedRange)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for character in ["a", "b", "c", "d", "e"] {
            editor.insertText(character, replacementRange: editor.selectedRange())
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(abs(clip.bounds.origin.y - initialY) < 35,
                    "평범한 본문 편집 중 화면이 \(initialY)에서 \(clip.bounds.origin.y)로 이동했습니다.")
        }
        #expect(editor.sourceText.contains("내용 abcde125"))
        #expect(!styledRanges.isEmpty)
        #expect(styledRanges.allSatisfy { $0.length < 250 },
                "키 입력 중 문서 전체의 텍스트 속성을 반복 변경했습니다: \(styledRanges)")
    }

    @Test func editingMarkdownSyntaxUpdatesHighlightAndKeepsUndo() throws {
        let text = "## 강조 제목\n평범한 본문\n" + String(repeating: "내용을 스크롤합니다.\n", count: 180)
        let position = EditorPosition()
        let undo = UndoManager()
        let hosting = NSHostingView(rootView: MarkdownEditor(text: .constant(text), blocks: [], position: position,
                                                              undoManager: undo, isEditable: true,
                                                              onFiles: { _ in }, onImage: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        let editor = try #require(position.editor)
        let storage = try #require(editor.textStorage)
        window.makeFirstResponder(editor)
        #expect((storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.controlAccentColor) == true)

        editor.insertText("", replacementRange: NSRange(location: 0, length: 3))
        hosting.layoutSubtreeIfNeeded()
        #expect(editor.sourceText.hasPrefix("강조 제목"))
        #expect((storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.textColor) == true)

        undo.undo()
        hosting.layoutSubtreeIfNeeded()
        #expect(editor.sourceText.hasPrefix("## 강조 제목"))
        #expect((storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.controlAccentColor) == true)
    }
}
