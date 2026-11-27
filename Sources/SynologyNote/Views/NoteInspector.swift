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
            library.errorMessage = appText("The managed Related Notes markers are damaged or duplicated. Check the body before adding a link.")
            return
        }
        guard updated != session.note.markdown else { return }
        library.edit(session, registerUndo: true) { $0.markdown = updated }
    }

    private func removeLink(to target: NoteSummary) {
        guard canManageLinks else { return }
        guard let updated = InternalNoteLinks.removeManagedLink(session.note.markdown, target: target) else {
            library.errorMessage = appText("Could not remove the link. Check the managed Related Notes section.")
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
        .confirmationDialog(appText("Remove Attachment from Note?"), isPresented: Binding(get: { attachmentToRemove != nil }, set: { if !$0 { attachmentToRemove = nil } }), presenting: attachmentToRemove) { attachment in
            Button(appText("Remove from Note"), role: .destructive) {
                attachmentToRemove = nil
                Task { await library.removeAttachment(attachment, from: session) }
            }
            Button(appText("Cancel"), role: .cancel) { attachmentToRemove = nil }
        } message: { attachment in
            Text(appText("%@\nAttachments in use stay in place. Local files and revision history are kept. The NAS removes the attachment when the note syncs.", attachment.name))
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
            InspectorPreview(title: AppLocalization.blockLabel(block.label)) { PreviewView(markdown: nil, originalHTML: block.html, blocks: [], attachments: session.note.attachments, assetStore: library.attachments) }
        }
        .sheet(item: $revisionToView) { revision in
            InspectorPreview(title: appText("Revision %@", AppLocalization.number(revision.number))) {
                VStack {
                    PreviewView(markdown: revision.note.mode == .markdown ? revision.note.markdown : nil, originalHTML: revision.note.originalHTML, blocks: revision.note.blocks, attachments: revision.note.attachments, assetStore: library.attachments)
                    Button(appText("Restore This Version")) {
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
            InspectorSection(appText("Note Info")) {
                LabeledContent(appText("Modified"), value: AppLocalization.date(session.note.modifiedAt))
                LabeledContent(appText("Revision Number"), value: AppLocalization.number(session.note.revision))
                HStack {
                    Text(appText("NAS Notebook"))
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(library.notebooks.filter { library.isNASNotebook($0.id) }) { book in
                            Button(book.name.isEmpty ? appText("Untitled Notebook") : book.name) {
                                library.edit(session) { $0.notebookID = book.id }
                            }.disabled(library.deletingNotebookIDs.contains(book.id))
                        }
                    } label: {
                        Text(library.notebooks.first(where: { $0.id == session.note.notebookID }).map { $0.name.isEmpty ? appText("Untitled Notebook") : $0.name } ?? appText("Preparing NAS Upload"))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .disabled(!library.canCreateNotes)
                    .accessibilityLabel(appText("Select NAS Notebook"))
                    .menuStyle(.borderlessButton)
                }
                .accessibilityElement(children: .contain)
                if let remote = session.note.remoteID { LabeledContent(appText("Server ID"), value: String(remote.prefix(12))).help(remote) }
                if let version = session.note.serverVersion {
                    LabeledContent(appText("Server Version")) {
                        Text(version).font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle).help(version)
                    }
                }
            }
            InspectorSection(appText("Tags")) {
                if session.note.tags.isEmpty { Text(appText("No Tags")).foregroundStyle(.secondary) }
                ForEach(session.note.tags, id: \.self) { tag in
                    HStack(spacing: 8) {
                        Text("#" + tag).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Button { library.edit(session) { $0.tags.removeAll { $0 == tag } } } label: {
                            IconButtonLabel(title: appText("Remove Tag"), systemImage: "xmark")
                        }.buttonStyle(.borderless).foregroundStyle(.secondary).help(appText("Remove Tag"))
                    }
                }
                HStack {
                    TextField(appText("Add Tag"), text: $tagInput).onSubmit(addTag)
                    Button(action: addTag) { IconButtonLabel(title: appText("Add Tag"), systemImage: "plus") }
                        .buttonStyle(.borderless).help(appText("Add Tag"))
                        .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            InspectorSection(appText("Outgoing Note Links")) {
                if outgoing.isEmpty { Text(appText("No Outgoing Note Links")).foregroundStyle(.secondary) }
                ForEach(outgoing) { node in
                    HStack(alignment: .center, spacing: 6) {
                        Button {
                            NotificationCenter.default.post(name: .openNote, object: node.id)
                        } label: {
                            Label(node.title.isEmpty ? appText("Untitled") : node.title, systemImage: "arrow.up.right")
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        if let target = library.summaries.first(where: { $0.id == node.id }),
                           InternalNoteLinks.hasManagedLink(session.note.markdown, to: target), canManageLinks {
                            Button { removeLink(to: target) } label: {
                                IconButtonLabel(title: appText("Remove Managed Link"), systemImage: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(appText("This removes the link from the managed section at the end of the body. Other links and the target note are kept."))
                            .accessibilityIdentifier("inspector-remove-managed-link")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if canManageLinks {
                    Button { showingLinkPicker = true } label: { Label(appText("＋ Link"), systemImage: "link.badge.plus") }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("inspector-add-note-link")
                    Text(appText("Links are added to the managed Related Notes section at the end of the body. Removal applies to links in that section. Other links and target notes are kept."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(appText("You can add and remove links in Markdown notes."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            InspectorSection(appText("Incoming Note Links")) {
                let sources = library.backlinks[session.id] ?? []
                if sources.isEmpty { Text(appText("No Incoming Note Links")).foregroundStyle(.secondary) }
                ForEach(sources) { source in
                    Button {
                        NotificationCenter.default.post(name: .openNote, object: source.id)
                    } label: {
                        Label(source.title.isEmpty ? appText("Untitled") : source.title, systemImage: "arrowshape.turn.up.left")
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                        .buttonStyle(.plain)
                }
            }
            InspectorSection(appText("Local Graph")) {
                NoteGraphExplorer(graph: library.noteGraph, notebooks: library.notebooks,
                                  focusID: session.id, compact: true) { id in
                    NotificationCenter.default.post(name: .openNote, object: id)
                }
                .frame(height: 255)
                Button(appText("Expand Graph")) { showingLocalGraph = true }
                    .buttonStyle(.borderless)
            }
            InspectorSection(appText("Attachments")) {
                if session.note.attachments.isEmpty { Text(appText("No Attachments")).foregroundStyle(.secondary) }
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
                            Button(appText("Show in Finder")) {
                                Task {
                                    do {
                                        _ = try await library.attachments.verifiedData(for: attachment)
                                        NSWorkspace.shared.activateFileViewerSelecting([await library.attachments.url(for: attachment)])
                                    } catch { library.errorMessage = error.localizedDescription }
                                }
                            }
                            Button(appText("Remove from Note…"), role: .destructive) { attachmentToRemove = attachment }
                                .disabled(session.note.mode == .locked || !session.note.hasRemoteContent || session.note.isTrashed)
                        } label: { IconButtonLabel(title: appText("Manage Attachments"), systemImage: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().help(appText("Manage Attachments"))
                    }
                }
                Button(appText("Preserved Blocks")) { library.pickAttachment(for: session) }.disabled(session.note.mode == .locked || session.note.isTrashed)
            }
            if !session.note.blocks.isEmpty {
                InspectorSection(appText("View Original")) {
                    ForEach(session.note.blocks) { block in
                        Menu {
                            Button(appText("Duplicate")) { blockToView = block }
                            Button(appText("Duplicate")) {
                                library.edit(session, registerUndo: true) { note in
                                    var copy = block; copy.id = UUID().uuidString
                                    note.blocks.append(copy)
                                    note.markdown += "\n\n" + MarkdownPipeline.token(for: copy) + "\n"
                                }
                            }
                        } label: { Label(AppLocalization.blockLabel(block.label), systemImage: "rectangle.on.rectangle") }
                    }
                    Text(appText("You can move or remove blocks in the body and restore them with Undo.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            InspectorSection(appText("Revision History on This Mac")) {
                if history.isEmpty { Text(appText("No Revisions")).foregroundStyle(.secondary) }
                ForEach(history.prefix(30)) { revision in
                    Button { revisionToView = revision } label: {
                        HStack { Text(appText("Revision %@", AppLocalization.number(revision.number))); Spacer(); Text(revision.savedAt, format: .dateTime.hour().minute().locale(AppLocalization.locale)).foregroundStyle(.secondary) }
                    }.buttonStyle(.plain)
                }
            }
            if session.note.remoteID != nil {
                InspectorSection(appText("NAS Revision History")) {
                    Button(appText("Load Server History")) { Task { await loadServerHistory() } }.disabled(!library.isConnected)
                    if let serverHistoryError { Text(serverHistoryError).foregroundStyle(.secondary) }
                    ForEach(serverHistory, id: \.version) { revision in
                        VStack(alignment: .leading, spacing: 3) { Text(revision.version); Text(revision.modifiedAt, format: .dateTime.locale(AppLocalization.locale)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if let error = AppLocalization.syncAttentionMessage(session.note.lastError) {
                InspectorSection(appText("NAS Status")) { Text(error).foregroundStyle(.orange).font(.caption) }
            }
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
        VStack(spacing: 0) { HStack { Text(title).font(.headline); Spacer(); Button(appText("Close")) { dismiss() } }.padding(); Divider(); content() }.frame(width: 720, height: 580)
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
