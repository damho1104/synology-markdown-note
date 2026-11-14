import AppKit
import SwiftUI
import Testing
import NoteCore
@testable import SynologyNote

@Suite(.serialized) @MainActor struct NoteLinkInteractionTests {
    @Test func pickerKeepsDistinctTitlesAndFiltersByNotebook() {
        let first = NoteRecord(title: "동일한 제목", notebookID: "one", markdown: "첫 번째 내용").summary
        let second = NoteRecord(title: "동일한 제목", notebookID: "two", markdown: "두 번째 내용").summary
        var trashed = NoteRecord(title: "삭제된 노트", notebookID: "one").summary
        trashed.isTrashed = true
        var locked = NoteRecord(title: "잠긴 노트", notebookID: "one").summary
        locked.mode = .locked

        let model = NoteLinkPickerModel(candidates: [first, second, trashed, locked],
                                        notebooks: [Notebook(id: "one", name: "하나"), Notebook(id: "two", name: "둘")])
        #expect(model.results.count == 2)
        #expect(Set(model.results.map(\.id)) == [first.id, second.id])
        #expect(model.notebook(first) == "하나")
        #expect(model.notebook(second) == "둘")
        model.query = "동일"
        #expect(model.results.count == 2)
        model.notebookID = "two"
        #expect(model.chosen?.id == second.id)
        model.step(1)
        #expect(model.chosen?.id == second.id)
        model.query = "없음"
        #expect(model.chosen == nil)
    }

    @Test func selectedLabelAndCaretInsertionUseNativeUndo() {
        let target = NoteRecord(title: "특수 [문자] (노트)").summary
        let editor = SourceTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let undo = UndoManager()
        editor.noteUndoManager = undo
        editor.allowsUndo = true
        editor.isEditable = true
        editor.string = "한글 문구 뒤"

        let range = (editor.string as NSString).range(of: "문구")
        editor.setSelectedRange(range)
        #expect(editor.insertNoteLink(target, replacing: range, label: "문구"))
        #expect(editor.sourceText == "한글 \(InternalNoteLinks.link("문구", target: target)) 뒤")
        #expect(editor.selectedRange().length == 0)
        undo.undo()
        #expect(editor.sourceText == "한글 문구 뒤")
        undo.redo()
        #expect(editor.sourceText == "한글 \(InternalNoteLinks.link("문구", target: target)) 뒤")

        let end = editor.string.utf16.count
        #expect(editor.insertNoteLink(target, replacing: NSRange(location: end, length: 0), label: target.title))
        #expect(editor.sourceText.hasSuffix(InternalNoteLinks.link(target.title, target: target)))
        editor.isEditable = false
        let previous = editor.sourceText
        #expect(!editor.insertNoteLink(target, replacing: editor.selectedRange(), label: "안 됨"))
        #expect(editor.sourceText == previous)
    }

    @Test func completionPopupPrefersRightAndBelowCaret() {
        let bounds = NSRect(x: 0, y: 0, width: 900, height: 700)
        let size = NSSize(width: 350, height: 280)
        let caret = NSRect(x: 120, y: 420, width: 2, height: 20)

        let normal = NoteCompletionPlacement.frame(caret: caret, within: bounds, size: size, flipped: false)
        #expect(normal.minX == caret.maxX + 6)
        #expect(normal.maxY == caret.minY - 6)

        let flippedCaret = NSRect(x: 120, y: 100, width: 2, height: 20)
        let flipped = NoteCompletionPlacement.frame(caret: flippedCaret, within: bounds, size: size, flipped: true)
        #expect(flipped.minX == flippedCaret.maxX + 6)
        #expect(flipped.minY == flippedCaret.maxY + 6)
    }

    @Test func completionPopupStaysVisibleAtEdges() {
        let bounds = NSRect(x: 0, y: 0, width: 460, height: 420)
        let size = NSSize(width: 350, height: 280)

        for flipped in [false, true] {
            let bottomCaret = NSRect(x: 430, y: flipped ? 390 : 5, width: 2, height: 18)
            let frame = NoteCompletionPlacement.frame(caret: bottomCaret, within: bounds,
                                                      size: size, flipped: flipped)
            #expect(frame.minX >= 8 && frame.maxX <= bounds.maxX - 8)
            #expect(frame.minY >= 8 && frame.maxY <= bounds.maxY - 8)
            if flipped { #expect(frame.maxY < bottomCaret.minY) }
            else { #expect(frame.minY > bottomCaret.maxY) }
        }

        let narrow = NoteCompletionPlacement.frame(
            caret: NSRect(x: 80, y: 100, width: 2, height: 18),
            within: NSRect(x: 0, y: 0, width: 240, height: 220), size: size, flipped: false
        )
        #expect(narrow.minX >= 8 && narrow.maxX <= 232)
        #expect(narrow.minY >= 8 && narrow.maxY <= 212)
    }

    @Test func completionPopupAppearsBesideCaretInRenderedEditor() throws {
        let target = NoteRecord(title: "테스트 문서", notebookID: "notes", markdown: "미리보기 예시").summary
        let position = EditorPosition()
        // Start with an empty line so [[ is followed by a newline; completion
        // deliberately rejects a caret placed in the middle of existing text.
        let markdown = MarkdownEditor(text: .constant("\n" + String(repeating: "본문 줄\n", count: 90)), blocks: [], position: position,
                                      undoManager: UndoManager(), isEditable: true,
                                      linkCandidates: [target], linkNotebooks: [Notebook(id: "notes", name: "개인 메모장")],
                                      onFiles: { _ in }, onImage: { _ in })
        let hosting = NSHostingView(rootView: markdown)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let editor = try #require(position.editor)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("[[", replacementRange: editor.selectedRange())
        let scroll = try #require(editor.enclosingScrollView)
        let popup = try #require(scroll.subviews.compactMap { $0 as? NSHostingView<NoteLinkPicker> }.first)
        #expect(scroll.bounds.width >= 350)
        #expect(popup.bounds.width >= 350)
        let caretOnScreen = editor.firstRect(forCharacterRange: NSRange(location: 2, length: 0), actualRange: nil)
        let caret = scroll.convert(window.convertFromScreen(caretOnScreen), from: nil)
        #expect(popup.frame.minX >= caret.maxX)
        #expect(popup.frame.height == 100)
        #expect(!popup.isHidden)
        if scroll.isFlipped { #expect(popup.frame.minY >= caret.maxY) }
        else { #expect(popup.frame.maxY <= caret.minY) }

        if let path = ProcessInfo.processInfo.environment["SYNONOTE_POPUP_SCREENSHOT"] {
            if ProcessInfo.processInfo.environment["SYNONOTE_POPUP_LIGHT"] == "1" {
                popup.appearance = NSAppearance(named: .aqua)
            }
            popup.layoutSubtreeIfNeeded()
            popup.displayIfNeeded()
            guard let bitmap = popup.bitmapImageRepForCachingDisplay(in: popup.bounds) else {
                Issue.record("자동완성 뷰가 렌더링 가능한 크기를 갖지 못했습니다")
                return
            }
            popup.cacheDisplay(in: popup.bounds, to: bitmap)
            let backgroundPixel = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 20)
            #expect((backgroundPixel?.alphaComponent ?? 0) >= 0.99)
            let image = try #require(bitmap.representation(using: .png, properties: [:]))
            try image.write(to: URL(fileURLWithPath: path))
        }

        if let path = ProcessInfo.processInfo.environment["SYNONOTE_EDITOR_SCREENSHOT"] {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }

        // Scrolling the caret out of view hides the popup; returning makes it visible again.
        let clip = scroll.contentView
        let documentHeight = try #require(scroll.documentView?.bounds.height)
        #expect(documentHeight > clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: documentHeight - clip.bounds.height))
        #expect(popup.isHidden)
        clip.scroll(to: .zero)
        #expect(!popup.isHidden)
    }
}
