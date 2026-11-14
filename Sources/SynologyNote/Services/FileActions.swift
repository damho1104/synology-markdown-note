import AppKit
import UniformTypeIdentifiers
import NoteCore

extension LibraryStore {
    func pickAttachment(for session: EditorSession) {
        let panel = NSOpenPanel()
        panel.title = "첨부파일 추가"; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in for url in panel.urls { await self.addAttachment(to: session, url: url) } }
        }
    }
    func importMarkdown() {
        guard canCreateNotes else { errorMessage = "NAS에 연결하고 메모장을 먼저 선택하세요."; return }
        let panel = NSOpenPanel()
        panel.title = "Markdown 가져오기"; panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                let generation = self.accountGeneration
                let repo = self.repository
                let store = self.attachments
                do {
                    let destination = try self.destinationNotebook()
                    for url in panel.urls {
                        var note = try await MarkdownFiles.importFile(url, store: store)
                        note.notebookID = destination
                        guard generation == self.accountGeneration else { return }
                        let saved = try await repo.save(note)
                        guard generation == self.accountGeneration else { return }
                        self.sessions[saved.id] = EditorSession(note: saved, workspaceGeneration: generation)
                        self.logEvent(.imported, noteID: saved.id, notebookID: destination)
                        NotificationCenter.default.post(name: .openNote, object: saved.id)
                    }
                    try await self.reload()
                    self.scheduleUpload()
                } catch { self.errorMessage = error.localizedDescription }
            }
        }
    }
    func exportMarkdown(_ session: EditorSession) {
        let panel = NSSavePanel()
        panel.title = "문서 내보내기"
        panel.allowedContentTypes = [session.note.mode == .original ? .html : (UTType(filenameExtension: "md") ?? .plainText)]
        panel.nameFieldStringValue = String((session.note.title.isEmpty ? "노트" : session.note.title).prefix(60)).replacingOccurrences(of: "/", with: "-") + (session.note.mode == .original ? ".html" : ".md")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let generation = self.accountGeneration
                let store = self.attachments
                do {
                    await self.save(session)
                    guard generation == self.accountGeneration, session.workspaceGeneration == generation else { return }
                    try await MarkdownFiles.export(session.note, to: url, store: store)
                } catch { self.errorMessage = error.localizedDescription }
            }
        }
    }
    func createNotebook() {
        guard canManageNASNotebooks else { errorMessage = "메모장을 만들려면 NAS에 연결하세요."; return }
        let generation = accountGeneration
        let alert = NSAlert()
        alert.messageText = "새 노트북"
        alert.informativeText = "NAS에 만들 메모장 이름을 입력하세요."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "노트북 이름"
        alert.accessoryView = input
        alert.addButton(withTitle: "만들기"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            guard generation == accountGeneration else { return }
            do { _ = try await createNotebook(named: name) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
