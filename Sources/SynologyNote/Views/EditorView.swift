import SwiftUI
import NoteCore

struct EditorView: View {
    @Environment(LibraryStore.self) private var library
    let session: EditorSession
    @Binding var mode: EditorMode
    @Binding var inspector: Bool
    var insertNoteLinkRequest = 0
    @State private var position = EditorPosition()
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
        let label = range.length > 0 ? linkLabel : (target.title.isEmpty ? "제목 없음" : target.title)
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
                    Text("이 Mac과 서버에 서로 다른 변경이 있습니다.").font(.callout)
                    Spacer()
                    Button("비교하기") { comparing = true }
                }.padding(12).background(.orange.opacity(0.08))
            }
            if session.note.isTrashed {
                HStack {
                    Label("휴지통에 있는 노트입니다", systemImage: "trash"); Spacer()
                    Button("복원") { library.toggleTrash(session) }
                    Button("영구 삭제…", role: .destructive) { library.promptPermanentlyDelete(session) }
                        .disabled(!library.canPermanentlyDelete(session.note))
                        .help("NAS 연결과 휴지통 동기화가 완료되면 영구 삭제할 수 있습니다.")
                }.padding(12).background(.quaternary)
            }
            if session.note.syncState == .failed {
                HStack {
                    Label("NAS 저장 결과 확인 중", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Button("다시 확인") { Task { await library.pushPendingUploads() } }.disabled(!library.isConnected || library.isPushing)
                }.padding(12).foregroundStyle(.secondary).background(.quaternary)
            }
            Divider()
            content
            Divider()
            statusBar
        }
        .navigationTitle(session.note.title.isEmpty ? "제목 없음" : session.note.title)
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
                TextField("제목", text: Binding(get: { session.note.title }, set: { value in library.edit(session) { $0.title = value } }))
                    .textFieldStyle(.plain).font(.system(size: 24, weight: .semibold)).accessibilityLabel("노트 제목")
                    .frame(maxWidth: .infinity).clipped().layoutPriority(1)
                    .disabled(session.note.mode == .locked || session.note.isTrashed)
                HStack(spacing: 4) {
                if canInsertLink {
                    Button(action: openLinkPicker) {
                        IconButtonLabel(title: "노트 연결", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("내부 노트 연결 (⇧⌘K)")
                    .accessibilityIdentifier("editor-insert-note-link")
                }
                Button { library.toggleFavorite(session) } label: {
                    IconButtonLabel(title: session.note.isFavorite ? "즐겨찾기 해제" : "즐겨찾기", systemImage: session.note.isFavorite ? "star.fill" : "star")
                }
                    .buttonStyle(.borderless).foregroundStyle(session.note.isFavorite ? .orange : .secondary)
                    .accessibilityLabel(session.note.isFavorite ? "즐겨찾기 해제" : "즐겨찾기")
                    .help(session.note.isFavorite ? "즐겨찾기 해제" : "즐겨찾기")
                Menu {
                    if canInsertLink {
                        Button("다른 노트 링크 삽입…", action: openLinkPicker)
                        Divider()
                    }
                    Button("Markdown 가져오기…") { library.importMarkdown() }
                    Button("내보내기…") { library.exportMarkdown(session) }
                    Button("첨부파일 추가…") { library.pickAttachment(for: session) }.disabled(session.note.mode == .locked || session.note.isTrashed)
                    Divider()
                    Button(session.note.isTrashed ? "복원" : "휴지통으로 이동") { library.toggleTrash(session) }
                    if session.note.isTrashed {
                        Button("영구 삭제…", role: .destructive) { library.promptPermanentlyDelete(session) }.disabled(!library.canPermanentlyDelete(session.note))
                    }
                } label: { IconButtonLabel(title: "노트 작업", systemImage: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize().frame(width: 28, height: 28).foregroundStyle(.secondary).help("노트 작업")
                }.fixedSize()
            }
            HStack(spacing: 9) {
                Label(library.notebooks.first(where: { $0.id == session.note.notebookID })?.name ?? "내 노트", systemImage: "book.closed")
                    .lineLimit(1)
                if !session.note.tags.isEmpty {
                    Text("·")
                    Text(session.note.tags.map { "#" + $0 }.joined(separator: "  ")).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if session.note.mode == .original && session.note.hasRemoteContent {
                    Button("Markdown으로 편집") { Task { await library.convert(session) } }.buttonStyle(.bordered).controlSize(.small).fixedSize()
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }

    @ViewBuilder private var content: some View {
        if session.note.mode == .locked {
            ContentUnavailableView("암호화된 노트", systemImage: "lock", description: Text("암호화 노트 편집은 아직 지원하지 않습니다. 공식 앱에서 열어 주세요."))
        } else if session.note.mode == .original && !session.note.hasRemoteContent {
            VStack(spacing: 16) {
                ContentUnavailableView(session.isDownloading ? "NAS에서 본문 가져오는 중…" : "본문을 가져와야 합니다",
                    systemImage: "arrow.down.document",
                    description: Text(session.note.lastError ?? "NAS에 연결한 뒤 이 노트의 본문과 첨부파일을 가져오세요."))
                if session.isDownloading { ProgressView() }
                else { Button("본문 다시 가져오기") { Task { await library.fetchContent(for: session) } }.disabled(!library.isConnected) }
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
                    MarkdownEditor(text: Binding(get: { session.note.markdown }, set: { value in library.edit(session) { $0.markdown = value } }), blocks: session.note.blocks, position: position, undoManager: session.undoManager, isEditable: !session.note.isTrashed && mode != .read, linkCandidates: library.summaries.filter { $0.id != session.id && $0.mode != .locked }, linkNotebooks: library.notebooks, onFiles: { urls in Task { for url in urls { await library.addAttachment(to: session, url: url) } } }, onImage: { data in Task { await library.addImage(to: session, data: data) } })
                }
                .frame(minWidth: mode == .read ? 0 : 220, maxWidth: mode == .read ? 0 : .infinity)
                .opacity(mode == .read ? 0 : 1)
                .accessibilityHidden(mode == .read)
                if mode != .source {
                    VStack(spacing: 0) {
                        if mode == .split { paneLabel("미리보기", icon: "eye") }
                        PreviewView(markdown: session.note.markdown, originalHTML: nil, blocks: session.note.activeBlocks, attachments: session.note.attachments, assetStore: library.attachments, onToggleTask: { line in
                            guard !session.note.isTrashed else { return }
                            library.edit(session, registerUndo: true) { $0.markdown = MarkdownEditing.toggleTask($0.markdown, line: line) }
                        }, onOpenNote: { destination in
                            Task { await library.openLinkedNote(destination, from: session.id) }
                        })
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
            if session.saveError != nil { Button("다시 저장") { Task { await library.save(session) } } }
            Spacer()
            if session.note.mode == .markdown {
                Text("\(session.note.markdown.count.formatted())자").monospacedDigit().foregroundStyle(.secondary).fixedSize()
            } else { Text("서식 문서").foregroundStyle(.secondary).fixedSize() }
            Divider().frame(height: 12)
            Label(nasStatus, systemImage: session.note.syncState == .synced ? "checkmark.icloud" : "externaldrive")
                .lineLimit(1).help(session.note.lastError ?? library.uploadStatus)
            if session.note.syncState == .failed {
                Button("반영 확인") { Task { await library.pushPendingUploads() } }.disabled(library.isPushing || !library.isConnected)
            }
        }.font(.system(size: 11)).imageScale(.small).foregroundStyle(.secondary)
            .padding(.horizontal, 20).frame(minHeight: 34)
    }
    private var nasStatus: String {
        switch session.note.syncState {
        case .synced: return "NAS 동기화됨"
        case .conflict: return "변경 비교 필요"
        case .failed: return "NAS 저장 확인 중"
        case .local: return "NAS 전송 준비"
        case .pending: return !library.isConnected ? "NAS 연결 대기" : library.isPushing ? "NAS 전송 중…" : "NAS 전송 대기"
        }
    }
}

private struct ConflictView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let session: EditorSession
    var body: some View {
        VStack(spacing: 16) {
            Text("서로 다른 변경 확인").font(.title2.bold())
            Text("한쪽을 선택해도 다른 버전은 로컬 이력 또는 사본으로 보관합니다.").foregroundStyle(.secondary)
            HSplitView {
                VStack { Text("이 Mac").font(.headline); PreviewView(markdown: session.note.mode == .markdown ? session.note.markdown : nil, originalHTML: session.note.originalHTML, blocks: session.note.blocks, attachments: session.note.attachments, assetStore: library.attachments) }
                VStack { Text("NAS").font(.headline); PreviewView(markdown: nil, originalHTML: session.note.conflictHTML, blocks: [], attachments: session.note.attachments, assetStore: library.attachments) }
            }
            HStack {
                Button("나중에") { dismiss() }; Spacer()
                Button("서버 버전 사용") { Task { await library.useServerConflict(session); dismiss() } }
                Button("이 Mac 버전 유지") { Task { await library.keepLocalConflict(session); dismiss() } }
            }
        }.padding(24).frame(width: 920, height: 620)
    }
}
