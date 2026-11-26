import SwiftUI
import NoteCore

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var filter: LibraryFilter = .all
    @State private var selection: UUID? = nil
    @State private var session: EditorSession? = nil
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var inspector = false
    @State private var insertNoteLinkRequest = 0
    @SceneStorage("editorModeV2") private var modeValue = EditorMode.read.rawValue
    @FocusState private var searchFocused: Bool
    @State private var showingGlobalSearch = false
    @State private var showingAdvancedSearch = false
    @State private var showingCreateStack = false
    @State private var initialStackSelection: Set<String> = []
    @State private var expandedStacks: Set<String> = []
    @State private var graphNavigation = NoteGraphNavigation()
    @State private var noteNavigation = NoteNavigationHistory()
    @AppStorage("noteListSortField") private var sortFieldValue = NoteSortField.modifiedAt.rawValue
    @AppStorage("noteListSortDirection") private var sortDirectionValue = NoteSortDirection.descending.rawValue

    private var mode: Binding<EditorMode> { Binding(get: { EditorMode(rawValue: modeValue) ?? .read }, set: { modeValue = $0.rawValue }) }
    private var stackExpansion: StackExpansionPreferences {
        StackExpansionPreferences(defaults: library.preferences, accountKey: library.profile.storageKey)
    }
    private var currentLocation: NoteNavigationHistory.Location {
        NoteNavigationHistory.Location(selection: selection, filter: filter, search: library.search,
                                       advancedTitle: library.advancedTitle, advancedTag: library.advancedTag,
                                       advancedNotebookID: library.advancedNotebookID,
                                       advancedAfter: library.advancedAfter, advancedBefore: library.advancedBefore,
                                       graph: filter == .graph ? graphNavigation.snapshot : nil)
    }
    private var rows: [NoteSummary] {
        NoteListSort(field: NoteSortField(rawValue: sortFieldValue) ?? .modifiedAt,
                     direction: NoteSortDirection(rawValue: sortDirectionValue) ?? .descending)
            .sorted(library.filtered(filter))
    }

    var body: some View {
        navigationContent
        .onAppear { expandedStacks = stackExpansion.load() }
        .focusedSceneValue(\.noteActions, NoteActions(newNote: newNote, save: { Task { if let session { await library.save(session) } } }, importNote: { library.importMarkdown() }, exportNote: { if let session { library.exportMarkdown(session) } }, togglePreview: togglePreview, search: { showingGlobalSearch = true }, undo: { session?.undoManager.undo() }, redo: { session?.undoManager.redo() }, insertNoteLink: { insertNoteLinkRequest += 1 }, canInsertNoteLink: session?.note.mode == .markdown && session?.note.isTrashed == false && mode.wrappedValue != .read))
        .task {
            if library.summaries.isEmpty { await library.load() }
            if selection == nil { selection = rows.first?.id }
            await library.restoreConnectionIfNeeded()
        }
        .task(id: library.profile.storageKey) {
            // Snapshot the currently selected NAS account and refresh the backup
            // while the app remains open. SQLite Backup API captures WAL writes.
            await library.backupActiveDatabase()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(6 * 60 * 60)) }
                catch { return }
                await library.backupActiveDatabase()
            }
        }
        .task(id: selection) {
            let target = selection
            if let target {
                let loaded = await library.session(for: target)
                guard selection == target else { return }
                session = loaded
            } else { session = nil }
        }
        .onChange(of: selection) { previous, _ in
            noteNavigation.observeSelection(currentLocation, previousID: previous)
        }
        .onChange(of: currentLocation) { previous, current in
            noteNavigation.updateContext(from: previous, to: current)
        }
        .onChange(of: graphNavigation.snapshot) { previous, current in
            noteNavigation.observeGraphChange(from: previous, to: current, location: currentLocation)
        }
        .onChange(of: filter) { _, newFilter in handleFilterChange(newFilter) }
        .onChange(of: library.search) { _, _ in library.searchChanged() }
        .onChange(of: library.profile.storageKey) { _, _ in
            showingGlobalSearch = false
            selection = nil; session = nil; filter = .all
            graphNavigation = NoteGraphNavigation()
            noteNavigation = NoteNavigationHistory()
            expandedStacks = stackExpansion.load()
        }
        .onChange(of: library.notebooks.map(\.id)) { _, ids in
            if case .notebook(let id) = filter, !ids.contains(id) {
                if let session, ids.contains(session.note.notebookID) { filter = .notebook(session.note.notebookID) }
                else { filter = .all }
            }
        }
        .onChange(of: library.stackNames) { previousNames, names in
            if case .stack(let name) = filter, !names.contains(name) {
                let replacements = names.filter { !previousNames.contains($0) }
                filter = replacements.count == 1 && previousNames.count == names.count ? .stack(replacements[0]) : .all
            }
        }
        .sheet(isPresented: $showingCreateStack, onDismiss: { initialStackSelection = [] }) {
            StackCreationSheet(initialSelection: initialStackSelection)
        }
        .sheet(isPresented: $showingGlobalSearch) {
            GlobalSearchSheet(library: library, onSelect: openGlobalSearchResult,
                              onClose: { showingGlobalSearch = false })
        }
        .onChange(of: library.summaries.map(\.id)) { _, ids in if selection == nil { selection = rows.first?.id } else if let selection, !ids.contains(selection) { self.selection = rows.first?.id } }
        .alert(library.errorMessage == nil ? appText("Stack Renamed") : appText("Review Required"),
               isPresented: Binding(
                get: { library.errorMessage != nil || library.stackSuccessMessage != nil },
                set: { if !$0 { library.errorMessage = nil; library.stackSuccessMessage = nil } }
               )) {
            Button(appText("OK")) { library.errorMessage = nil; library.stackSuccessMessage = nil }
        } message: { Text(library.errorMessage ?? library.stackSuccessMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .openNote), perform: handleOpenNote)
    }

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
        } content: {
            libraryContent
        } detail: {
            editorContent
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Spacer()
                    Text("NAS").font(.caption2).foregroundStyle(.secondary)
                    Circle()
                        .fill(library.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                }
                .padding(.horizontal, 12)
                .frame(height: 25)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(appText(library.isConnected ? "Connected to NAS" : "Disconnected from NAS"))
                .help(library.connectionStatus)
            }
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: goBack) { IconButtonLabel(title: appText("Go Back"), systemImage: "chevron.backward") }
                    .disabled(!noteNavigation.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help(appText("Go Back (⌘[)"))
                Button(action: goForward) { IconButtonLabel(title: appText("Go Forward"), systemImage: "chevron.forward") }
                    .disabled(!noteNavigation.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help(appText("Go Forward (⌘])"))
                Button(action: newNote) { IconButtonLabel(title: appText("New Note"), systemImage: "square.and.pencil") }
                    .disabled(!library.canCreateNotes)
                    .help(appText("New Note (⌘N)"))
                Button { showingGlobalSearch = true } label: { IconButtonLabel(title: appText("Global Search"), systemImage: "magnifyingglass") }
                    .help(appText("Global Search (⇧⌘F)"))
                Button { showingAdvancedSearch.toggle() } label: { IconButtonLabel(title: appText("Advanced Search"), systemImage: "line.3.horizontal.decrease.circle") }
                    .help(appText("Advanced Search and Save Smart Notebook"))
            }
            if session?.note.mode == .markdown {
                ToolbarItem(placement: .primaryAction) {
                    Picker(appText("View Mode"), selection: mode) {
                        ForEach(EditorMode.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 168).help(appText("Editor View Mode"))
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if session?.note.mode == .markdown {
                    Button { togglePreview() } label: { IconButtonLabel(title: appText("Preview"), systemImage: "rectangle.split.2x1") }
                        .foregroundStyle(mode.wrappedValue == .split ? Color.accentColor : Color.secondary)
                        .accessibilityValue(mode.wrappedValue == .split ? appText("On") : appText("Off"))
                        .help(appText("Toggle Preview (⇧⌘P)"))
                }
                Button {
                    library.logEvent(.inspectorRequested, noteID: session?.id, fields: ["visible": String(!inspector)])
                    inspector.toggle()
                } label: { IconButtonLabel(title: appText("Note Info"), systemImage: "sidebar.right") }
                    .foregroundStyle(inspector ? Color.accentColor : Color.secondary)
                    .accessibilityValue(inspector ? appText("On") : appText("Off"))
                    .disabled(session == nil).help(appText("Note Info"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await library.refreshFromServer() } } label: {
                    if library.isRefreshing {
                        ProgressView().controlSize(.small).frame(width: 28, height: 28)
                    } else {
                        IconButtonLabel(title: appText("Refresh NAS"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }.disabled(!library.isConnected || library.isRefreshing || library.isPushing)
                    .help(appText("Refresh NAS List · ") + library.connectionStatus)
                    .accessibilityLabel(appText("Refresh NAS"))
            }
        }
    }

    private func handleFilterChange(_ newFilter: LibraryFilter) {
        if noteNavigation.current == currentLocation { return }
        if case .smart = newFilter {
            library.resetAdvancedFilters()
            library.search = ""
            library.searchChanged()
        }
        if newFilter != .graph && !(selection.map { id in rows.contains(where: { $0.id == id }) } ?? false) {
            selection = rows.first?.id
        }
        noteNavigation.navigate(from: noteNavigation.current ?? currentLocation, to: currentLocation)
    }

    private func handleOpenNote(_ notification: Notification) {
        guard let id = notification.object as? UUID,
              let note = library.summaries.first(where: { $0.id == id && !$0.isTrashed }) else { return }
        let origin = currentLocation
        library.search = ""
        library.searchChanged()
        library.resetAdvancedFilters()
        // Linked notes may be outside the current notebook or smart search.
        if filter == .graph || !library.filtered(filter).contains(where: { $0.id == note.id }) { filter = .all }
        selection = id
        noteNavigation.navigate(from: origin, to: currentLocation)
    }

    private func openGlobalSearchResult(_ id: UUID) {
        guard library.summaries.contains(where: { $0.id == id && !$0.isTrashed }) else { return }
        let destination = noteNavigation.openGlobalSearchResult(id, from: currentLocation)
        restore(destination)
        showingGlobalSearch = false
    }

    @ViewBuilder private var libraryContent: some View {
        @Bindable var library = library
            if filter == .graph {
                NoteGraphNavigationPanel(graph: library.noteGraph, notebooks: library.notebooks,
                                         navigation: graphNavigation) { id in
                    NotificationCenter.default.post(name: .openNote, object: id)
                }
                .navigationSplitViewColumnWidth(min: 210, ideal: 270, max: 380)
            } else {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20, height: 20)
                    TextField(appText("Search Notes"), text: $library.search)
                        .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel(appText("Search All Notes"))
                    if !library.search.isEmpty {
                        Button { library.search = "" } label: { IconButtonLabel(title: appText("Clear Search"), systemImage: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help(appText("Clear Search"))
                    }
                }.padding(12)
                if showingAdvancedSearch { AdvancedSearchControls(library: library) }
                HStack(spacing: 6) {
                    Picker(appText("Sort Notes By"), selection: $sortFieldValue) {
                        Text(appText("Title")).tag(NoteSortField.title.rawValue)
                        Text(appText("Date Added")).tag(NoteSortField.createdAt.rawValue)
                        Text(appText("Date Modified")).tag(NoteSortField.modifiedAt.rawValue)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .help(appText("Sort by title, date added, or date modified. Notes without a date added use their date modified."))
                    Picker(appText("Note Sort Direction"), selection: $sortDirectionValue) {
                        Text(appText("Ascending")).tag(NoteSortDirection.ascending.rawValue)
                        Text(appText("Descending")).tag(NoteSortDirection.descending.rawValue)
                    }
                    .labelsHidden()
                    .frame(width: 94)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                Divider()
                if rows.isEmpty {
                    ContentUnavailableView(library.search.isEmpty ? appText("No Notes") : appText("No Results"), systemImage: "note.text", description: Text(library.search.isEmpty ? appText("Create a new note to get started.") : appText("Try a different search term.")))
                } else {
                    List(rows, selection: $selection) { note in
                        NoteRow(note: note, showsCreatedAt: sortFieldValue == NoteSortField.createdAt.rawValue).tag(note.id)
                            .contextMenu {
                                Button(note.isFavorite ? appText("Remove from Favorites") : appText("Favorites")) { Task { if let target = await library.session(for: note.id, waitForContent: true) { library.toggleFavorite(target) } } }
                                Button(note.isTrashed ? appText("Restore Note") : appText("Move to Trash")) { Task { if let target = await library.session(for: note.id, waitForContent: true) { library.toggleTrash(target) } } }
                                if note.isTrashed {
                                    Button(appText("Delete Permanently…"), role: .destructive) { Task { if let target = await library.session(for: note.id) { library.promptPermanentlyDelete(target) } } }
                                        .disabled(!library.isConnected || library.isPushing || library.isRefreshing || (note.syncState != .synced && note.syncState != .local))
                                }
                            }
                    }
                    .listStyle(.inset)
                    .frame(maxHeight: .infinity)
                    .clipped()
                }
                Divider()
                HStack(spacing: 6) {
                    Text(appText("Notes: %@", AppLocalization.number(rows.count)))
                    Spacer(minLength: 4)
                    if library.isCachingOffline {
                        ProgressView().controlSize(.mini)
                        Text("\(library.offlineCompleted)/\(library.offlineTotal)").monospacedDigit()
                            .help(library.offlineStatus).accessibilityLabel(library.offlineStatus)
                    } else if library.isRefreshing { ProgressView().controlSize(.small) }
                }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 9)
            }
            .navigationTitle(filterTitle)
            .navigationSplitViewColumnWidth(min: 210, ideal: 270, max: 380)
            }
    }

    @ViewBuilder private var editorContent: some View {
            if filter == .graph {
                NoteGraphExplorer(graph: library.noteGraph, notebooks: library.notebooks,
                                  navigation: graphNavigation) { id in
                    NotificationCenter.default.post(name: .openNote, object: id)
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            } else {
            HSplitView {
                Group {
                    if let session { EditorView(session: session, mode: mode, inspector: $inspector, insertNoteLinkRequest: insertNoteLinkRequest).id(session.id) }
                    else { ContentUnavailableView(library.profile.server.isEmpty ? appText("Connect to the NAS") : appText("Select a Note"), systemImage: "externaldrive", description: Text(appText("Notes and attachments sync with the NAS automatically."))) }
                }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                if inspector, let session {
                    NoteInspector(session: session).environment(library).id(session.id)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360, maxHeight: .infinity)
                }
            }
            }
    }

    private var filterTitle: String {
        if case .notebook(let id) = filter { return library.notebooks.first(where: { $0.id == id })?.name ?? appText("Notebook") }
        if case .stack(let name) = filter { return name }
        if case .smart(let id) = filter { return library.savedSearches.first(where: { $0.id == id })?.name ?? appText("Smart Notebook") }
        return filter.title
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $filter) {
                Section {
                    Label(appText("All Notes"), systemImage: "note.text").tag(LibraryFilter.all)
                    Label(appText("Favorites"), systemImage: "star").tag(LibraryFilter.favorites)
                    Label(appText("Note Graph"), systemImage: "point.3.connected.trianglepath.dotted").tag(LibraryFilter.graph)
                }
                stackSection
                if !library.savedSearches.isEmpty {
                    Section(appText("Smart Notebook")) {
                        ForEach(library.savedSearches) { saved in
                            Label(saved.name, systemImage: "line.3.horizontal.decrease.circle")
                                .tag(LibraryFilter.smart(saved.id))
                                .contextMenu {
                                    Button(appText("Delete Smart Notebook"), role: .destructive) {
                                        if filter == .smart(saved.id) { filter = .all }
                                        Task { await library.deleteSavedSearch(id: saved.id) }
                                    }
                                }
                        }
                    }
                }
                if !library.tags.isEmpty {
                    Section(appText("Tags")) { ForEach(library.tags, id: \.self) { tag in Label(tag, systemImage: "number").tag(LibraryFilter.tag(tag)) } }
                }
                Section { Label(appText("Trash"), systemImage: "trash").tag(LibraryFilter.trash) }
            }
            .listStyle(.sidebar)
            .labelStyle(SidebarItemLabelStyle())
            .frame(maxHeight: .infinity)

            Divider()
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.profile.server.isEmpty ? appText("NAS Account Required") : library.profile.username)
                        .font(.caption.weight(.medium))
                    Text(library.connectionStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(library.connectionError ?? library.connectionStatus)
                }
                Spacer(minLength: 8)
                SettingsLink { IconButtonLabel(title: appText("Note Station Settings"), systemImage: "gearshape") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(appText("Note Station Settings"))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .navigationTitle("Note Station")
    }
    private var stackSection: some View {
        Section(appText("Stacks and Notebooks")) {
            ForEach(library.stackNames, id: \.self) { name in stackRow(name) }
            Label(appText("Notebooks Outside Stacks"), systemImage: "tray")
                .font(.caption).foregroundStyle(.secondary)
                .dropDestination(for: String.self) { ids, _ in dropNotebooks(ids, into: "") }
            ForEach(library.notebooks.filter { $0.stack.isEmpty }) { notebook in notebookRow(notebook) }
            Button { initialStackSelection = []; showingCreateStack = true } label: { Label(appText("Create Stack"), systemImage: "books.vertical.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(!library.canManageNASNotebooks || library.isRefreshing || library.isPushing || library.isManagingStacks)
            Button { library.createNotebook() } label: { Label(appText("Add Notebook"), systemImage: "plus") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(!library.canManageNASNotebooks)
        }
    }

    private func stackRow(_ name: String) -> some View {
        let expanded = Binding<Bool>(
            get: { expandedStacks.contains(name) },
            set: { expandedStacks = stackExpansion.setExpanded($0, for: name) }
        )
        return DisclosureGroup(isExpanded: expanded) {
            ForEach(notebooksSortedByName(in: name)) { notebook in notebookRow(notebook) }
        } label: {
            Label(name, systemImage: "books.vertical").onTapGesture { filter = .stack(name) }
                // Scope the stack menu to its header so it cannot override
                // the context menus of notebooks inside the disclosure group.
                .contextMenu {
                    Button(appText("View Notes in Stack")) { filter = .stack(name) }
                    Button(appText("Rename…")) { library.promptRenameStack(name) }
                    Button(appText("Delete Stack…"), role: .destructive) { library.promptDeleteStack(name) }
                }
        }
        .tag(LibraryFilter.stack(name))
        .dropDestination(for: String.self) { ids, _ in dropNotebooks(ids, into: name) }
    }
    private func notebooksSortedByName(in stack: String) -> [Notebook] {
        library.notebooks.filter { $0.stack == stack }.sorted { lhs, rhs in
            let leftName = lhs.name.isEmpty ? appText("Untitled Notebook") : lhs.name
            let rightName = rhs.name.isEmpty ? appText("Untitled Notebook") : rhs.name
            let comparison = leftName.localizedStandardCompare(rightName)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }
    private func notebookRow(_ notebook: Notebook) -> some View {
        Label(notebook.name.isEmpty ? appText("Untitled Notebook") : notebook.name, systemImage: "book.closed")
            .tag(LibraryFilter.notebook(notebook.id))
            .help(notebook.name)
            .draggable(notebook.id)
            .contextMenu {
                Button(appText("Rename…")) { library.promptRenameNotebook(notebook) }
                    .disabled(!library.isNASNotebook(notebook.id) || !library.canManageNASNotebooks)
                Menu(appText("Move to Stack")) {
                    ForEach(library.stackNames.filter { $0 != notebook.stack }, id: \.self) { name in
                        Button(name) { library.promptMoveNotebook(notebook, to: name) }
                    }
                    Button(appText("Create New Stack…")) {
                        initialStackSelection = [notebook.id]
                        showingCreateStack = true
                    }
                }
                .disabled(!library.canManageNASNotebooks || library.isRefreshing || library.isPushing || library.isManagingStacks)
                if !notebook.stack.isEmpty {
                    Button(appText("Remove from Stack")) { library.promptMoveNotebook(notebook, to: "") }
                        .disabled(!library.canManageNASNotebooks || library.isRefreshing || library.isPushing || library.isManagingStacks)
                }
                Divider()
                Button(appText("Delete Notebook…"), role: .destructive) { library.promptDeleteNotebook(notebook) }
                    .disabled(!library.isNASNotebook(notebook.id) || !library.canManageNASNotebooks || library.isPushing || library.isRefreshing)
            }
    }

    private func dropNotebooks(_ ids: [String], into name: String) -> Bool {
        let allowed = Array(Set(ids)).filter { id in library.notebooks.contains { $0.id == id && library.isNASNotebook(id) } }
        guard !allowed.isEmpty, library.canManageNASNotebooks, !library.isRefreshing, !library.isPushing, !library.isManagingStacks else { return false }
        let account = library.accountGeneration
        Task {
            guard account == library.accountGeneration else { return }
            do { try await library.moveNotebooksToStack(ids: allowed, name: name) }
            catch { if account == library.accountGeneration { library.errorMessage = error.localizedDescription } }
        }
        return true
    }
    private func newNote() {
        Task {
            let notebook: String?
            if case .notebook(let id) = filter { notebook = id } else { notebook = nil }
            if let id = await library.newNote(notebookID: notebook) {
                let origin = currentLocation
                filter = .all
                selection = id
                noteNavigation.navigate(from: origin, to: currentLocation)
            }
        }
    }
    private func goBack() {
        if let destination = noteNavigation.goBack(allowing: isAvailable) { restore(destination) }
    }
    private func goForward() {
        if let destination = noteNavigation.goForward(allowing: isAvailable) { restore(destination) }
    }
    private func isAvailable(_ location: NoteNavigationHistory.Location) -> Bool {
        if location.filter == .graph { return true }
        guard let id = location.selection else { return true }
        guard let note = library.summaries.first(where: { $0.id == id }) else { return false }
        return note.isTrashed == (location.filter == .trash)
    }
    private func restore(_ location: NoteNavigationHistory.Location) {
        let location = location.reconciled(notebookIDs: Set(library.notebooks.map(\.id)),
                                           stackNames: Set(library.stackNames),
                                           savedSearchIDs: Set(library.savedSearches.map(\.id)))
        noteNavigation.replaceCurrent(location)
        library.search = location.search
        library.advancedTitle = location.advancedTitle
        library.advancedTag = location.advancedTag
        library.advancedNotebookID = location.advancedNotebookID
        library.advancedAfter = location.advancedAfter
        library.advancedBefore = location.advancedBefore
        library.searchChanged()
        if let graph = location.graph { graphNavigation.restore(graph) }
        filter = location.filter
        selection = location.selection
    }
    private func togglePreview() { mode.wrappedValue = mode.wrappedValue == .split ? .source : .split }
}

struct StackExpansionPreferences {
    let defaults: UserDefaults
    let accountKey: String

    private var key: String { "expandedStacks.v1.\(accountKey)" }

    func load() -> Set<String> {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }

    @discardableResult
    func setExpanded(_ expanded: Bool, for name: String) -> Set<String> {
        var names = load()
        if expanded { names.insert(name) } else { names.remove(name) }
        if let data = try? JSONEncoder().encode(names) { defaults.set(data, forKey: key) }
        return names
    }
}

private struct StackCreationSheet: View {
    let initialSelection: Set<String>
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appText("Create New Stack")).font(.title3.weight(.semibold))
            TextField(appText("Stack Name"), text: $name)
            Text(appText("Choose the notebooks to put in the stack.")).foregroundStyle(.secondary)
            List(library.notebooks.filter { library.isNASNotebook($0.id) }) { notebook in
                Toggle(isOn: Binding(
                    get: { selected.contains(notebook.id) },
                    set: { checked in
                        if checked { selected.insert(notebook.id) }
                        else { selected.remove(notebook.id) }
                    }
                )) { Text(notebook.name.isEmpty ? appText("Untitled Notebook") : notebook.name) }
            }
            .frame(minHeight: 180)
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack {
                Spacer()
                Button(appText("Cancel")) { dismiss() }
                Button(appText("Create")) {
                    let account = library.accountGeneration
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    errorText = nil
                    saving = true
                    Task {
                        do {
                            try await library.moveNotebooksToStack(ids: Array(selected).sorted(), name: trimmed, creatingNew: true)
                            if account == library.accountGeneration { dismiss() }
                        } catch {
                            if account == library.accountGeneration { errorText = error.localizedDescription }
                        }
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !library.canManageNASNotebooks || library.isManagingStacks || selected.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.stackNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        .padding(20)
        .frame(width: 390)
        .onAppear { selected.formUnion(initialSelection) }
    }
}

private struct NoteRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let note: NoteSummary
    let showsCreatedAt: Bool

    private var markdownBadge: some View {
        Text("MD")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.10), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(colorScheme == .dark ? 0.35 : 0.16), lineWidth: 0.5)
            }
            .fixedSize()
            .help(appText("Markdown Note"))
            .accessibilityLabel(appText("Markdown Note"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                if note.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                Text(note.title.isEmpty ? appText("Untitled") : note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if note.syncState == .conflict { Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange).help(appText("Conflicting Edits Need Review")) }
                if note.syncState == .failed { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).help(appText("Verifying NAS Save")) }
                if note.mode == .locked { Image(systemName: "lock").foregroundStyle(.secondary) }
                if note.mode == .markdown { markdownBadge }
            }
            Text(note.excerpt.isEmpty ? (note.mode == .original ? appText("Original Formatted Document") : appText("No Content")) : note.excerpt)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            if showsCreatedAt {
                if let createdAt = note.createdAt {
                    Text(appText("Added: %@", createdAt.formatted(.dateTime.month().day().hour().minute().locale(AppLocalization.locale))))
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text(appText("Date added unavailable · Modified: %@", note.modifiedAt.formatted(.dateTime.month().day().hour().minute().locale(AppLocalization.locale))))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Text(note.modifiedAt, format: .dateTime.month().day().hour().minute().locale(AppLocalization.locale)).font(.caption2).foregroundStyle(.tertiary)
            }
        }.padding(.vertical, 8).accessibilityElement(children: .combine)
    }
}

extension Notification.Name { static let openNote = Notification.Name("SynologyMarkdown.openNote") }

private struct AdvancedSearchControls: View {
    @Bindable var library: LibraryStore
    @State private var smartName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(appText("Title Contains"), text: $library.advancedTitle)
            TextField(appText("Tag Contains"), text: $library.advancedTag)
            Picker(appText("Notebook"), selection: $library.advancedNotebookID) {
                Text(appText("All Notebooks")).tag(nil as String?)
                ForEach(library.notebooks) { notebook in
                    Text(notebook.name).tag(Optional(notebook.id))
                }
            }
            Toggle(appText("Start Date"), isOn: Binding(
                get: { library.advancedAfter != nil },
                set: { library.advancedAfter = $0 ? (library.advancedAfter ?? .now) : nil }
            ))
            if library.advancedAfter != nil {
                DatePicker(appText("After"), selection: Binding(
                    get: { library.advancedAfter ?? .now }, set: { library.advancedAfter = $0 }
                ), displayedComponents: .date)
            }
            Toggle(appText("End Date"), isOn: Binding(
                get: { library.advancedBefore != nil },
                set: { library.advancedBefore = $0 ? (library.advancedBefore ?? .now) : nil }
            ))
            if library.advancedBefore != nil {
                DatePicker(appText("Before"), selection: Binding(
                    get: { library.advancedBefore ?? .now }, set: { library.advancedBefore = $0 }
                ), displayedComponents: .date)
            }
            HStack {
                TextField(appText("Smart Notebook Name"), text: $smartName)
                Button(appText("Save")) {
                    Task { await library.saveCurrentSearch(name: smartName); smartName = "" }
                }.disabled(smartName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(appText("Reset")) { library.resetAdvancedFilters(); library.search = "" }
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }
}
