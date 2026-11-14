import SwiftUI
import NoteCore

struct NoteInspector: View {
    @Environment(LibraryStore.self) private var library
    let session: EditorSession
    @State private var history: [NoteRevision] = []
    @State private var serverHistory: [RemoteRevision] = []
    @State private var serverHistoryError: String? = nil
    @State private var attachmentToRemove: NoteAttachment? = nil
    @State private var tagInput = ""
    @State private var blockToView: PreservedBlock? = nil
    @State private var revisionToView: NoteRevision? = nil
    @State private var showingLocalGraph = false
    @State private var showingLinkPicker = false

    private var canManageLinks: Bool {
        session.note.mode == .markdown && !session.note.isTrashed && session.note.hasRemoteContent
    }

    private var outgoing: [NoteGraphNode] {
        library.noteGraph.connections(of: session.id).outgoing
    }

    private func addLink(to target: NoteSummary) {
        showingLinkPicker = false
        guard canManageLinks, target.id != session.id, !target.isTrashed else { return }
        guard let updated = InternalNoteLinks.addManagedLink(session.note.markdown, target: target) else {
            library.errorMessage = "관련 노트 관리 영역의 마커가 손상되거나 중복되어 연결을 추가할 수 없습니다. 본문을 확인해 주세요."
            return
        }
        guard updated != session.note.markdown else { return }
        library.edit(session, registerUndo: true) { $0.markdown = updated }
    }

    private func removeLink(to target: NoteSummary) {
        guard canManageLinks else { return }
        guard let updated = InternalNoteLinks.removeManagedLink(session.note.markdown, target: target) else {
            library.errorMessage = "관련 노트 관리 영역을 확인할 수 없어 연결을 제거하지 못했습니다."
            return
        }
        guard updated != session.note.markdown else { return }
        library.edit(session, registerUndo: true) { $0.markdown = updated }
    }

    var body: some View {
        ScrollView { inspectorSections.padding(12) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { library.logEvent(.inspectorOpened, noteID: session.id) }
        .onDisappear { library.logEvent(.inspectorClosed, noteID: session.id) }
        .confirmationDialog("첨부파일을 노트에서 제거할까요?", isPresented: Binding(get: { attachmentToRemove != nil }, set: { if !$0 { attachmentToRemove = nil } }), presenting: attachmentToRemove) { attachment in
            Button("노트에서 제거", role: .destructive) {
                attachmentToRemove = nil
                Task { await library.removeAttachment(attachment, from: session) }
            }
            Button("취소", role: .cancel) { attachmentToRemove = nil }
        } message: { attachment in
            Text("\(attachment.name)\n본문에서 사용 중이면 제거하지 않습니다. 로컬 파일과 수정 이력은 보존되며 NAS 삭제는 동기화할 때 반영됩니다.")
        }
        .task(id: session.note.revision) { do { history = try await library.repository.revisions(noteID: session.id) } catch { library.errorMessage = error.localizedDescription } }
        .task(id: session.id) { await library.loadBacklinks(for: session.id) }
        .sheet(isPresented: $showingLocalGraph) {
            NoteGraphExplorer(graph: library.noteGraph, notebooks: library.notebooks,
                              focusID: session.id) { id in
                showingLocalGraph = false
                NotificationCenter.default.post(name: .openNote, object: id)
            }
            .frame(minWidth: 850, minHeight: 590)
        }
        .sheet(isPresented: $showingLinkPicker) {
            NoteLinkPickerSheet(
                candidates: library.summaries.filter { $0.id != session.id && $0.mode != .locked },
                notebooks: library.notebooks, onSelect: addLink,
                onCancel: { showingLinkPicker = false })
        }
        .onChange(of: library.summaries) { _, _ in Task { await library.loadBacklinks(for: session.id) } }
        .sheet(item: $blockToView) { block in
            InspectorPreview(title: block.label) { PreviewView(markdown: nil, originalHTML: block.html, blocks: [], attachments: session.note.attachments, assetStore: library.attachments) }
        }
        .sheet(item: $revisionToView) { revision in
            InspectorPreview(title: "변경 \(revision.number)") {
                VStack {
                    PreviewView(markdown: revision.note.mode == .markdown ? revision.note.markdown : nil, originalHTML: revision.note.originalHTML, blocks: revision.note.blocks, attachments: revision.note.attachments, assetStore: library.attachments)
                    Button("이 버전으로 복원") {
                        library.edit(session, registerUndo: true) { note in
                            note.markdown = revision.note.markdown; note.blocks = revision.note.blocks
                            note.mode = revision.note.mode; note.originalHTML = revision.note.originalHTML; note.attachments = revision.note.attachments
                        }
                        revisionToView = nil
                    }.padding(.bottom)
                }
            }
        }
    }
    private var inspectorSections: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("노트 정보") {
                LabeledContent("수정", value: session.note.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("변경 번호", value: String(session.note.revision))
                HStack {
                    Text("NAS 메모장")
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(library.notebooks.filter { library.isNASNotebook($0.id) }) { book in
                            Button(book.name.isEmpty ? "이름 없는 메모장" : book.name) {
                                library.edit(session) { $0.notebookID = book.id }
                            }.disabled(library.deletingNotebookIDs.contains(book.id))
                        }
                    } label: {
                        Text(library.notebooks.first(where: { $0.id == session.note.notebookID }).map { $0.name.isEmpty ? "이름 없는 메모장" : $0.name } ?? "NAS 전송 준비 중")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .disabled(!library.canCreateNotes)
                    .accessibilityLabel("NAS 메모장 선택")
                    .menuStyle(.borderlessButton)
                }
                .accessibilityElement(children: .contain)
                if let remote = session.note.remoteID { LabeledContent("서버 ID", value: String(remote.prefix(12))).help(remote) }
                if let version = session.note.serverVersion {
                    LabeledContent("서버 버전") {
                        Text(version).font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle).help(version)
                    }
                }
            }
            InspectorSection("태그") {
                if session.note.tags.isEmpty { Text("태그 없음").foregroundStyle(.secondary) }
                ForEach(session.note.tags, id: \.self) { tag in
                    HStack(spacing: 8) {
                        Text("#" + tag).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Button { library.edit(session) { $0.tags.removeAll { $0 == tag } } } label: {
                            IconButtonLabel(title: "태그 제거", systemImage: "xmark")
                        }.buttonStyle(.borderless).foregroundStyle(.secondary).help("태그 제거")
                    }
                }
                HStack {
                    TextField("태그 추가", text: $tagInput).onSubmit(addTag)
                    Button(action: addTag) { IconButtonLabel(title: "태그 추가", systemImage: "plus") }
                        .buttonStyle(.borderless).help("태그 추가")
                        .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            InspectorSection("내가 연결한 노트") {
                if outgoing.isEmpty { Text("연결한 노트 없음").foregroundStyle(.secondary) }
                ForEach(outgoing) { node in
                    HStack(alignment: .center, spacing: 6) {
                        Button {
                            NotificationCenter.default.post(name: .openNote, object: node.id)
                        } label: {
                            Label(node.title.isEmpty ? "제목 없음" : node.title, systemImage: "arrow.up.right")
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        if let target = library.summaries.first(where: { $0.id == node.id }),
                           InternalNoteLinks.hasManagedLink(session.note.markdown, to: target), canManageLinks {
                            Button { removeLink(to: target) } label: {
                                IconButtonLabel(title: "관리 영역에서 연결만 제거", systemImage: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("본문 끝 관리 영역의 연결만 제거합니다. 본문 다른 링크와 대상 노트는 유지됩니다.")
                            .accessibilityIdentifier("inspector-remove-managed-link")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if canManageLinks {
                    Button { showingLinkPicker = true } label: { Label("＋ 연결", systemImage: "link.badge.plus") }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("inspector-add-note-link")
                    Text("추가한 연결은 본문 끝의 ‘관련 노트 (앱에서 관리)’ 영역에 저장됩니다. 제거는 이 영역의 링크만 대상으로 하며 다른 본문 링크나 대상 노트는 삭제하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Markdown 노트에서 연결을 추가하거나 제거할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            InspectorSection("나를 참조하는 노트") {
                let sources = library.backlinks[session.id] ?? []
                if sources.isEmpty { Text("참조하는 노트 없음").foregroundStyle(.secondary) }
                ForEach(sources) { source in
                    Button {
                        NotificationCenter.default.post(name: .openNote, object: source.id)
                    } label: {
                        Label(source.title.isEmpty ? "제목 없음" : source.title, systemImage: "arrowshape.turn.up.left")
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                        .buttonStyle(.plain)
                }
            }
            InspectorSection("로컬 그래프") {
                NoteGraphExplorer(graph: library.noteGraph, notebooks: library.notebooks,
                                  focusID: session.id, compact: true) { id in
                    NotificationCenter.default.post(name: .openNote, object: id)
                }
                .frame(height: 255)
                Button("그래프 크게 보기") { showingLocalGraph = true }
                    .buttonStyle(.borderless)
            }
            InspectorSection("첨부파일") {
                if session.note.attachments.isEmpty { Text("첨부파일 없음").foregroundStyle(.secondary) }
                ForEach(session.note.attachments) { attachment in
                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            Task {
                                do { _ = try await library.attachments.verifiedData(for: attachment); NSWorkspace.shared.open(await library.attachments.url(for: attachment)) }
                                catch { library.errorMessage = error.localizedDescription }
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "paperclip").font(.system(size: 13)).foregroundStyle(.secondary)
                                    .frame(width: 20, height: 18)
                                Text(attachment.name).lineLimit(2).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).help(attachment.name)
                        Menu {
                            Button("Finder에서 보기") {
                                Task {
                                    do {
                                        _ = try await library.attachments.verifiedData(for: attachment)
                                        NSWorkspace.shared.activateFileViewerSelecting([await library.attachments.url(for: attachment)])
                                    } catch { library.errorMessage = error.localizedDescription }
                                }
                            }
                            Button("노트에서 제거…", role: .destructive) { attachmentToRemove = attachment }
                                .disabled(session.note.mode == .locked || !session.note.hasRemoteContent || session.note.isTrashed)
                        } label: { IconButtonLabel(title: "첨부파일 관리", systemImage: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().help("첨부파일 관리")
                    }
                }
                Button("파일 추가…") { library.pickAttachment(for: session) }.disabled(session.note.mode == .locked || session.note.isTrashed)
            }
            if !session.note.blocks.isEmpty {
                InspectorSection("원본 보존 블록") {
                    ForEach(session.note.blocks) { block in
                        Menu {
                            Button("원본 보기") { blockToView = block }
                            Button("복제") {
                                library.edit(session, registerUndo: true) { note in
                                    var copy = block; copy.id = UUID().uuidString
                                    note.blocks.append(copy)
                                    note.markdown += "\n\n" + MarkdownPipeline.token(for: copy) + "\n"
                                }
                            }
                        } label: { Label(block.label, systemImage: "rectangle.on.rectangle") }
                    }
                    Text("블록은 본문에서 이동·삭제할 수 있으며 실행 취소로 복원됩니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
            InspectorSection("이 Mac에 보관된 수정 이력") {
                if history.isEmpty { Text("수정 이력 없음").foregroundStyle(.secondary) }
                ForEach(history.prefix(30)) { revision in
                    Button { revisionToView = revision } label: {
                        HStack { Text("변경 \(revision.number)"); Spacer(); Text(revision.savedAt, format: .dateTime.hour().minute()).foregroundStyle(.secondary) }
                    }.buttonStyle(.plain)
                }
            }
            if session.note.remoteID != nil {
                InspectorSection("NAS 수정 이력") {
                    Button("서버 이력 조회") { Task { await loadServerHistory() } }.disabled(!library.isConnected)
                    if let serverHistoryError { Text(serverHistoryError).foregroundStyle(.secondary) }
                    ForEach(serverHistory, id: \.version) { revision in
                        VStack(alignment: .leading, spacing: 3) { Text(revision.version); Text(revision.modifiedAt, format: .dateTime).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if let error = session.note.lastError { InspectorSection("NAS 상태") { Text(error).foregroundStyle(.orange).font(.caption) } }
        }
    }

    private func addTag() {
        let tag = tagInput.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !tag.isEmpty, !session.note.tags.contains(tag) else { return }
        library.edit(session) { $0.tags.append(tag) }; tagInput = ""
    }
    private func loadServerHistory() async {
        guard let client = library.client, let id = session.note.remoteID else { return }
        do { serverHistory = try await client.versionHistory(noteID: id); serverHistoryError = nil }
        catch { serverHistoryError = error.localizedDescription }
    }
}

private struct InspectorPreview<Content: View>: View {
    @Environment(\.dismiss) var dismiss
    var title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { HStack { Text(title).font(.headline); Spacer(); Button("닫기") { dismiss() } }.padding(); Divider(); content() }.frame(width: 720, height: 580)
    }
}

/// A grouped Form imposes a 508pt minimum on this content on macOS. Inspector
/// sections must accept the actual split-pane width instead of centering and
/// clipping a settings-sized form inside a 260–360pt column.
private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
