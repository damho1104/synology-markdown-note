import SwiftUI

struct NoteActions {
    var newNote: () -> Void
    var save: () -> Void
    var importNote: () -> Void
    var exportNote: () -> Void
    var togglePreview: () -> Void
    var search: () -> Void
    var undo: () -> Void
    var redo: () -> Void
    var insertNoteLink: () -> Void
    var canInsertNoteLink: Bool
}
struct NoteActionsKey: FocusedValueKey { typealias Value = NoteActions }
extension FocusedValues {
    var noteActions: NoteActions? {
        get { self[NoteActionsKey.self] }
        set { self[NoteActionsKey.self] = newValue }
    }
}
struct NoteCommands: Commands {
    @FocusedValue(\.noteActions) var actions
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("실행 취소") { actions?.undo() }.keyboardShortcut("z")
            Button("다시 실행") { actions?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .newItem) {
            Button("새 노트") { actions?.newNote() }.keyboardShortcut("n").disabled(actions == nil)
            Button("Markdown 가져오기…") { actions?.importNote() }.keyboardShortcut("o").disabled(actions == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("지금 저장") { actions?.save() }.keyboardShortcut("s").disabled(actions == nil)
            Button("내보내기…") { actions?.exportNote() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(actions == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("문서에서 찾기") { NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: FindSender.shared) }.keyboardShortcut("f")
            Button("전체 노트 검색") { actions?.search() }.keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandMenu("Markdown") {
            Button("굵게") { send(#selector(SourceTextView.markdownBold(_:))) }.keyboardShortcut("b")
            Button("기울임") { send(#selector(SourceTextView.markdownItalic(_:))) }.keyboardShortcut("i")
            Button("링크 삽입") { send(#selector(SourceTextView.markdownLink(_:))) }.keyboardShortcut("k")
            Button("다른 노트 링크 삽입…") { actions?.insertNoteLink() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(actions?.canInsertNoteLink != true)
            Button("인라인 코드") { send(#selector(SourceTextView.markdownCode(_:))) }.keyboardShortcut("`", modifiers: [.command])
            Button("표 삽입") { send(#selector(SourceTextView.markdownTable(_:))) }
        }
        CommandGroup(after: .sidebar) {
            Button("미리보기 켜기·끄기") { actions?.togglePreview() }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
    private func send(_ selector: Selector) { NSApp.sendAction(selector, to: nil, from: nil) }
}
private final class FindSender: NSObject {
    static let shared = FindSender()
    @objc var tag: Int { NSTextFinder.Action.showFindInterface.rawValue }
}
