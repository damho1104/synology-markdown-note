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
            Button(appText("Undo")) { actions?.undo() }.keyboardShortcut("z")
            Button(appText("Redo")) { actions?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .newItem) {
            Button(appText("New Note")) { actions?.newNote() }.keyboardShortcut("n").disabled(actions == nil)
            Button(appText("Import Markdown…")) { actions?.importNote() }.keyboardShortcut("o").disabled(actions == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button(appText("Save Now")) { actions?.save() }.keyboardShortcut("s").disabled(actions == nil)
            Button(appText("Export…")) { actions?.exportNote() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(actions == nil)
        }
        CommandGroup(after: .textEditing) {
            Button(appText("Find in Document")) { NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: FindSender.shared) }.keyboardShortcut("f")
            Button(appText("Search All Notes")) { actions?.search() }.keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandMenu("Markdown") {
            Button(appText("Bold")) { send(#selector(SourceTextView.markdownBold(_:))) }.keyboardShortcut("b")
            Button(appText("Italic")) { send(#selector(SourceTextView.markdownItalic(_:))) }.keyboardShortcut("i")
            Button(appText("Insert Link")) { send(#selector(SourceTextView.markdownLink(_:))) }.keyboardShortcut("k")
            Button(appText("Insert Link to Another Note…")) { actions?.insertNoteLink() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(actions?.canInsertNoteLink != true)
            Button(appText("Inline Code")) { send(#selector(SourceTextView.markdownCode(_:))) }.keyboardShortcut("`", modifiers: [.command])
            Button(appText("Insert Table")) { send(#selector(SourceTextView.markdownTable(_:))) }
        }
        CommandGroup(after: .sidebar) {
            Button(appText("Toggle Preview")) { actions?.togglePreview() }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
    private func send(_ selector: Selector) { NSApp.sendAction(selector, to: nil, from: nil) }
}
private final class FindSender: NSObject {
    static let shared = FindSender()
    @objc var tag: Int { NSTextFinder.Action.showFindInterface.rawValue }
}
