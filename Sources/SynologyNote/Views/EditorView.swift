import SwiftUI
import NoteCore

struct EditorView: View {
    @Environment(LibraryStore.self) private var library
    let session: EditorSession
    @Binding var mode: EditorMode
    @Binding var inspector: Bool
    var insertNoteLinkRequest = 0
    @State private var position = EditorPosition()
    @State private var previewLine: Int?
    @State private var comparing = false
    @State private var showingLinkPicker = false
    @State private var linkSelection = NSRange(location: 0, length: 0)
    @State private var linkSourceSnapshot = ""
    @State private var linkEditor: SourceTextView?
    @State private var linkLabel = ""

    private var canInsertLink: Bool {
        session.note.mode == .markdown && !session.note.isTrashed && mode != .read
    }

    private func openLinkPicker() {
        guard canInsertLink, let editor = position.editor, editor.isEditable,
              !editor.hasMarkedText() else { return }
        linkSelection = editor.selectedRange()
        linkSourceSnapshot = editor.sourceText
        linkEditor = editor
        if linkSelection.length > 0 && NSMaxRange(linkSelection) <= editor.attributedString().length {
            linkLabel = SourceTextView.source(from: editor.attributedString().attributedSubstring(from: linkSelection))
        } else { linkLabel = "" }
        showingLinkPicker = true
    }

    private func insertLink(_ target: NoteSummary) {
        showingLinkPicker = false
        guard canInsertLink, let editor = position.editor, editor === linkEditor,
              editor.sourceText == linkSourceSnapshot,
              NSMaxRange(linkSelection) <= editor.attributedString().length else { return }
        let range = linkSelection
        let label = range.length > 0 ? linkLabel : (target.title.isEmpty ? appText("Untitled") : target.title)
        if editor.insertNoteLink(target, replacing: range, label: label) {
            editor.window?.makeFirstResponder(editor)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if session.note.syncState == .conflict {
                HStack {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                    Text(appText("This Mac and the server have different changes.")).font(.callout)
                    Spacer()
                    Button(appText("Compare")) { comparing = true }
                }.padding(12).background(.orange.opacity(0.08))
            }
            if session.note.isTrashed {
                HStack {
                    Label(appText("This note is in the Trash"), systemImage: "trash"); Spacer()
                    Button(appText("Restore")) { library.toggleTrash(session) }
                    Button(appText("Delete Permanently…"), role: .destructive) { library.promptPermanentlyDelete(session) }
                        .disabled(!library.canPermanentlyDelete(session.note))
                        .help(appText("Connect to the NAS and sync the Trash to permanently delete this note."))
                }.padding(12).background(.quaternary)
            }
            if session.note.syncState == .failed {
                HStack {
                    Label(appText("Verifying NAS Save"), systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Button(appText("Check Again")) { Task { await library.pushPendingUploads() } }.disabled(!library.isConnected || library.isPushing)
                }.padding(12).foregroundStyle(.secondary).background(.quaternary)
            }
            Divider()
            content
            Divider()
            statusBar
        }
        .navigationTitle(session.note.title.isEmpty ? appText("Untitled") : session.note.title)
        .sheet(isPresented: $comparing) { ConflictView(session: session) }
        .sheet(isPresented: $showingLinkPicker) {
            NoteLinkPickerSheet(candidates: library.summaries.filter { $0.id != session.id && $0.mode != .locked }, notebooks: library.notebooks,
                onSelect: insertLink, onCancel: { showingLinkPicker = false })
        }
        .onChange(of: insertNoteLinkRequest) { _, _ in openLinkPicker() }
        .id(session.id)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                TextField(appText("Title"), text: Binding(get: { session.note.title }, set: { value in library.edit(session) { $0.title = value } }))
                    .textFieldStyle(.plain).font(.system(size: 24, weight: .semibold)).accessibilityLabel(appText("Note Title"))
                    .frame(maxWidth: .infinity).clipped().layoutPriority(1)
                    .disabled(session.note.mode == .locked || session.note.isTrashed)
                HStack(spacing: 4) {
                if canInsertLink {
                    Button(action: openLinkPicker) {
                        IconButtonLabel(title: appText("Link Notes"), systemImage: "link.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help(appText("Link to a Note (⇧⌘K)"))
                    .accessibilityIdentifier("editor-insert-note-link")
                }
                Button { library.toggleFavorite(session) } label: {
                    IconButtonLabel(title: session.note.isFavorite ? appText("Remove from Favorites") : appText("Favorites"), systemImage: session.note.isFavorite ? "star.fill" : "star")
                }
                    .buttonStyle(.borderless).foregroundStyle(session.note.isFavorite ? .orange : .secondary)
                    .accessibilityLabel(session.note.isFavorite ? appText("Remove from Favorites") : appText("Favorites"))
                    .help(session.note.isFavorite ? appText("Remove from Favorites") : appText("Favorites"))
                Menu {
                    if canInsertLink {
                        Button(appText("Insert Link to Another Note…"), action: openLinkPicker)
                        Divider()
                    }
                    Button(appText("Import Markdown…")) { library.importMarkdown() }
                    Button(appText("Export…")) { library.exportMarkdown(session) }
                    Button(appText("Add Attachments…")) { library.pickAttachment(for: session) }.disabled(session.note.mode == .locked || session.note.isTrashed)
                    Divider()
                    Button(session.note.isTrashed ? appText("Restore") : appText("Move to Trash")) { library.toggleTrash(session) }
                    if session.note.isTrashed {
                        Button(appText("Delete Permanently…"), role: .destructive) { library.promptPermanentlyDelete(session) }.disabled(!library.canPermanentlyDelete(session.note))
                    }
                } label: { IconButtonLabel(title: appText("Note Actions"), systemImage: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize().frame(width: 28, height: 28).foregroundStyle(.secondary).help(appText("Note Actions"))
                }.fixedSize()
            }
            HStack(spacing: 9) {
                Label(library.notebooks.first(where: { $0.id == session.note.notebookID })?.name ?? appText("My Notes"), systemImage: "book.closed")
                    .lineLimit(1)
                if !session.note.tags.isEmpty {
                    Text("·")
                    Text(session.note.tags.map { "#" + $0 }.joined(separator: "  ")).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if session.note.mode == .original && session.note.hasRemoteContent {
                    Button(appText("Edit as Markdown")) { Task { await library.convert(session) } }.buttonStyle(.bordered).controlSize(.small).fixedSize()
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }

    @ViewBuilder private var content: some View {
        if session.note.mode == .locked {
            ContentUnavailableView(appText("Encrypted Note"), systemImage: "lock", description: Text(appText("Editing encrypted notes is not supported yet. Open the note in the official app.")))
        } else if session.note.mode == .original && !session.note.hasRemoteContent {
            VStack(spacing: 16) {
                ContentUnavailableView(session.isDownloading ? appText("Downloading Note Body from NAS…") : appText("Note Body Needs Downloading"),
                    systemImage: "arrow.down.document",
                    description: Text(session.note.lastError ?? appText("Connect to the NAS to download the note body and attachments.")))
                if session.isDownloading { ProgressView() }
                else { Button(appText("Retry Note Download")) { Task { await library.fetchContent(for: session) } }.disabled(!library.isConnected) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.note.mode == .original {
            OriginalHTMLEditor(html: Binding(get: { session.note.originalHTML }, set: { value in
                library.edit(session) { $0.originalHTML = value }
            }), attachments: session.note.attachments, assetStore: library.attachments,
            isEditable: !session.note.isTrashed, undoManager: session.undoManager,
            onFiles: { urls in Task { for url in urls { await library.addAttachment(to: session, url: url) } } },
            onImage: { data in Task { await library.addImage(to: session, data: data) } })
        } else {
            HSplitView {
                // Kept mounted in read mode to retain native undo, selection and scroll state.
                VStack(spacing: 0) {
                    if mode == .split { paneLabel("MARKDOWN", icon: "chevron.left.forwardslash.chevron.right") }
                    MarkdownEditor(text: Binding(get: { session.note.markdown }, set: { value in library.edit(session) { $0.markdown = value } }), blocks: session.note.blocks, position: position, undoManager: session.undoManager, isEditable: !session.note.isTrashed && mode != .read, onSourceLine: { previewLine = $0 }, linkCandidates: library.summaries.filter { $0.id != session.id && $0.mode != .locked }, linkNotebooks: library.notebooks, onFiles: { urls in Task { for url in urls { await library.addAttachment(to: session, url: url) } } }, onImage: { data in Task { await library.addImage(to: session, data: data) } })
                }
                .frame(minWidth: mode == .read ? 0 : 220, maxWidth: mode == .read ? 0 : .infinity)
                .opacity(mode == .read ? 0 : 1)
                .accessibilityHidden(mode == .read)
                if mode != .source {
                    VStack(spacing: 0) {
                        if mode == .split { paneLabel(appText("Preview"), icon: "eye") }
                        PreviewView(markdown: session.note.markdown, originalHTML: nil, blocks: session.note.activeBlocks, attachments: session.note.attachments, assetStore: library.attachments, onToggleTask: { line in
                            guard !session.note.isTrashed else { return }
                            library.edit(session, registerUndo: true) { $0.markdown = MarkdownEditing.toggleTask($0.markdown, line: line) }
                        }, onOpenNote: { destination in
                            Task { await library.openLinkedNote(destination, from: session.id) }
                        }, sourceLine: mode == .split ? previewLine : nil)
                    }.frame(minWidth: 220)
                }
            }
        }
    }
    private func paneLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).frame(width: 16, height: 16)
            Text(title)
            Spacer()
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 22).frame(height: 32)
    }
    private var statusBar: some View {
        HStack(spacing: 10) {
            Label(session.localStatus, systemImage: session.saveError != nil ? "exclamationmark.circle" : session.isSaving ? "circle.dotted" : "checkmark.circle")
                .foregroundStyle(session.saveError != nil ? .red : .secondary).lineLimit(1)
            if session.saveError != nil { Button(appText("Save Again")) { Task { await library.save(session) } } }
            Spacer()
            if session.note.mode == .markdown {
                Text(appText("Characters: %@", AppLocalization.number(session.note.markdown.count))).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            } else { Text(appText("Formatted Document")).foregroundStyle(.secondary).fixedSize() }
            Divider().frame(height: 12)
            Label(nasStatus, systemImage: session.note.syncState == .synced ? "checkmark.icloud" : "externaldrive")
                .lineLimit(1).help(session.note.lastError ?? library.uploadStatus)
            if session.note.syncState == .failed {
                Button(appText("Verify")) { Task { await library.pushPendingUploads() } }.disabled(library.isPushing || !library.isConnected)
            }
        }.font(.system(size: 11)).imageScale(.small).foregroundStyle(.secondary)
            .padding(.horizontal, 20).frame(minHeight: 34)
    }
    private var nasStatus: String {
        switch session.note.syncState {
        case .synced: return appText("Synced with NAS")
        case .conflict: return appText("Compare Changes")
        case .failed: return appText("Verifying NAS Save")
        case .local: return appText("Preparing NAS Upload")
        case .pending: return !library.isConnected ? appText("Waiting for NAS Connection") : library.isPushing ? appText("Uploading to the NAS…") : appText("Waiting to Upload")
        }
    }
}

private struct ConflictView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let session: EditorSession
    var body: some View {
        VStack(spacing: 16) {
            Text(appText("Review Conflicting Changes")).font(.title2.bold())
            Text(appText("Whichever version you choose, the other is kept in local history or as a copy.")).foregroundStyle(.secondary)
            HSplitView {
                VStack { Text(appText("This Mac")).font(.headline); PreviewView(markdown: session.note.mode == .markdown ? session.note.markdown : nil, originalHTML: session.note.originalHTML, blocks: session.note.blocks, attachments: session.note.attachments, assetStore: library.attachments) }
                VStack { Text("NAS").font(.headline); PreviewView(markdown: nil, originalHTML: session.note.conflictHTML, blocks: [], attachments: session.note.attachments, assetStore: library.attachments) }
            }
            HStack {
                Button(appText("Later")) { dismiss() }; Spacer()
                Button(appText("Use Server Version")) { Task { await library.useServerConflict(session); dismiss() } }
                Button(appText("Keep This Mac’s Version")) { Task { await library.keepLocalConflict(session); dismiss() } }
            }
        }.padding(24).frame(width: 920, height: 620)
    }
}
