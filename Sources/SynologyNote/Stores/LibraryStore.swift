import AppKit
import Foundation
import Observation
import CryptoKit
import NoteCore

@MainActor @Observable
final class LibraryStore {
    var summaries: [NoteSummary] = []
    var notebooks: [Notebook] = []
    var stackNames: [String] { Array(Set(notebooks.map(\.stack).filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var sessions: [UUID: EditorSession] = [:]
    var search = ""
    var fullTextMatches: Set<UUID> = []
    private(set) var searchIndexRevision = 0
    var advancedTitle = ""
    var advancedTag = ""
    var advancedNotebookID: String? = nil
    var advancedAfter: Date? = nil
    var advancedBefore: Date? = nil
    var savedSearches: [SavedSearch] = []
    var savedSearchMatches: [UUID: Set<UUID>] = [:]
    var backlinks: [UUID: [NoteSummary]] = [:]
    var noteGraph = NoteGraph()
    var errorMessage: String?
    var stackSuccessMessage: String?
    var connectionStatus = appText("Disconnected from NAS")
    var isRefreshing = false
    var isConnected = false
    var hasVerifiedNASLists = false
    var isNASAvailable: Bool { isConnected && hasVerifiedNASLists }
    var profile: ConnectionProfile
    var connectionError: String?
    var loginStorageMessage: String?
    var loginStorageIssue: LoginStorageIssue?
    var trustedDeviceRemembered = false
    @ObservationIgnored var credentialAccess = NASCredentialAccess.keychain
    @ObservationIgnored var clientFactory: @Sendable (URL, Bool) -> NoteStationClient = { NoteStationClient(baseURL: $0, allowsValidatedWrites: $1) }
    var isPushing = false
    var deletingNotebookIDs: Set<String> = []
    var isManagingStacks = false
    var deletingNoteIDs: Set<UUID> = []
    var uploadStatus = appText("Automatic Sync After NAS Connection")
    @ObservationIgnored var uploadTask: Task<Void, Never>?
    @ObservationIgnored var uploadLoop: Task<Void, Never>?
    @ObservationIgnored var syncCoordinator: SyncCoordinator?
    @ObservationIgnored var uploadTransport: NoteStationSyncTransport?
    @ObservationIgnored var uploadAgain = false
    @ObservationIgnored var attemptedStartupConnection = false
    @ObservationIgnored var connectionGeneration = 0
    @ObservationIgnored var repository: NoteRepository
    @ObservationIgnored var attachments: AttachmentStore
    @ObservationIgnored var client: NoteStationClient?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored var localReloadTask: Task<Void, Never>?
    @ObservationIgnored private var localChangeVersion = 0
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var recoveryTask: Task<Void, Never>?
    @ObservationIgnored var recoveryID: UUID?
    @ObservationIgnored var recoveryAllowed = true
    @ObservationIgnored var recoveryBlocked = false
    @ObservationIgnored var recoveryStartedAt: ContinuousClock.Instant?
    @ObservationIgnored var recoveryExpired = false
    @ObservationIgnored var recoveryWindow: Duration = ConnectionRetrySchedule.maximumDuration
    @ObservationIgnored var lastConnectionFailure: Error?
    @ObservationIgnored var recoveryDelay: @Sendable (Int) -> Duration = { ConnectionRetrySchedule.delay($0) }
    @ObservationIgnored var connectionEvents: ConnectionEvents?
    @ObservationIgnored var offlineTask: Task<Void, Never>?
    @ObservationIgnored var offlineRunID = UUID()
    var isCachingOffline = false
    var offlineStatus = appText("Preparing Offline Download")
    var offlineCompleted = 0
    var offlineTotal = 0
    var offlineFailures: [UUID: String] = [:]
    @ObservationIgnored let root: URL
    @ObservationIgnored let preferences: UserDefaults
    var diagnosticLogPolicy = DiagnosticLogPolicy()
    @ObservationIgnored var diagnosticLog: DiagnosticLog?
    @ObservationIgnored var accountGeneration = 0

    init() throws {
        let initialRoot = Self.storageRoot()
        // Isolated build/run verification must not restore the real NAS account.
        let initialPreferences = NoteLocalization.preferences
        let initialProfile = ConnectionProfile.load(from: initialPreferences)
        root = initialRoot
        preferences = initialPreferences
        profile = initialProfile
        let directory = initialRoot.appendingPathComponent(initialProfile.storageKey)
        let initialPolicy = DiagnosticLogPolicy.load(from: preferences)
        diagnosticLogPolicy = initialPolicy
        let log = DiagnosticLog(root: initialRoot, policy: initialPolicy)
        diagnosticLog = log
        repository = try NoteRepository(directory: directory, diagnostics: log.maintenanceObserver(account: initialProfile.storageKey))
        attachments = try AttachmentStore(directory: directory.appendingPathComponent("assets"))
        connectionEvents = ConnectionEvents(store: self)
        logEvent(.appStarted)
    }

    init(root initialRoot: URL, profile initialProfile: ConnectionProfile, preferences: UserDefaults = .standard) throws {
        root = initialRoot
        self.preferences = preferences
        profile = initialProfile
        let directory = initialRoot.appendingPathComponent(initialProfile.storageKey)
        let initialPolicy = DiagnosticLogPolicy.load(from: preferences)
        diagnosticLogPolicy = initialPolicy
        let log = DiagnosticLog(root: initialRoot, policy: initialPolicy)
        diagnosticLog = log
        repository = try NoteRepository(directory: directory, diagnostics: log.maintenanceObserver(account: initialProfile.storageKey))
        attachments = try AttachmentStore(directory: directory.appendingPathComponent("assets"))
        logEvent(.appStarted)
    }

    static func storageRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["SYNOLOGY_NOTE_DATA_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SynologyMarkdown", isDirectory: true)
    }

    func load() async {
        do {
            try await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    func backupActiveDatabase() async {
        let generation = accountGeneration, repo = repository
        do { _ = try await repo.backupIfNeeded() }
        catch {
            if generation == accountGeneration {
                errorMessage = appText("Could not back up the local database automatically: %@", "\(error.localizedDescription)")
            }
        }
    }

    var canCreateNotes: Bool { !profile.server.isEmpty && notebooks.contains { isNASNotebook($0.id) && !deletingNotebookIDs.contains($0.id) } }
    func destinationNotebook(preferred: String? = nil) throws -> String {
        guard !profile.server.isEmpty else { throw RepositoryError(message: appText("Connect a NAS account first.")) }
        if let preferred, isNASNotebook(preferred), !deletingNotebookIDs.contains(preferred) { return preferred }
        guard let book = notebooks.first(where: { isNASNotebook($0.id) && !deletingNotebookIDs.contains($0.id) }) else {
            throw RepositoryError(message: appText("Connect to the NAS and create a notebook. You can keep writing in a downloaded NAS notebook when offline."))
        }
        return book.id
    }

    func reload() async throws {
        let repo = repository
        let generation = accountGeneration
        let changeVersion = localChangeVersion
        let rows = try await repo.listNotes()
        let books = try await repo.notebooks()
        let searches = try await repo.savedSearches()
        let graph = try await repo.noteGraph(summaries: rows)
        var matches: [UUID: Set<UUID>] = [:]
        for search in searches where !search.query.isEmpty {
            matches[search.id] = try await repo.searchNoteIDs(search.query)
        }
        guard generation == accountGeneration, changeVersion == localChangeVersion, !Task.isCancelled else { return }
        summaries = rows; notebooks = books; savedSearches = searches; savedSearchMatches = matches; noteGraph = graph
        // HTML body downloads can update the index without changing a summary.
        searchIndexRevision &+= 1
        if !search.isEmpty { searchChanged() }
    }

    /// Update the visible row immediately after a committed local write.
    /// The heavier graph/search rebuild happens after the editor can respond.
    private func applyLocalNote(_ note: NoteRecord) {
        localChangeVersion += 1
        summaries.removeAll { $0.id == note.id }
        summaries.insert(note.summary, at: 0)
        noteGraph.nodes.removeAll { $0.id == note.id }
        if !note.isTrashed {
            noteGraph.nodes.append(NoteGraphNode(id: note.id, title: note.title, notebookID: note.notebookID, tags: note.tags))
        } else {
            noteGraph.edges.removeAll { $0.sourceID == note.id || $0.targetID == note.id }
        }
    }

    private func scheduleLocalReload() {
        localReloadTask?.cancel()
        let generation = accountGeneration
        localReloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                guard let self, generation == self.accountGeneration else { return }
                try await self.reload()
            } catch is CancellationError {
            } catch {
                if let self, generation == self.accountGeneration { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func resetAdvancedFilters() {
        advancedTitle = ""; advancedTag = ""; advancedNotebookID = nil
        advancedAfter = nil; advancedBefore = nil
    }

    func saveCurrentSearch(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = appText("Enter a name for the smart notebook."); return }
        do {
            try await repository.saveSearch(SavedSearch(name: trimmed, query: search, title: advancedTitle, tag: advancedTag,
                                                        notebookID: advancedNotebookID, modifiedAfter: advancedAfter, modifiedBefore: advancedBefore))
            try await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteSavedSearch(id: UUID) async {
        do { try await repository.deleteSearch(id: id); try await reload() }
        catch { errorMessage = error.localizedDescription }
    }

    func loadBacklinks(for id: UUID) async {
        let generation = accountGeneration, repo = repository
        do {
            let sources = try await repo.backlinks(to: id)
            guard generation == accountGeneration else { return }
            backlinks[id] = sources
        } catch { errorMessage = error.localizedDescription }
    }

    func openLinkedNote(_ destination: String, from id: UUID) async {
        let generation = accountGeneration, repo = repository
        do {
            let target = try await repo.resolveLink(destination, from: id)
            guard generation == accountGeneration else { return }
            NotificationCenter.default.post(name: .openNote, object: target)
        } catch { if generation == accountGeneration { errorMessage = error.localizedDescription } }
    }

    func filtered(_ filter: LibraryFilter) -> [NoteSummary] {
        let stackMembers: Set<String>
        if case .stack(let name) = filter { stackMembers = Set(notebooks.filter { $0.stack == name }.map(\.id)) }
        else { stackMembers = [] }
        return summaries.filter { note in
            let included: Bool
            switch filter {
            case .all: included = !note.isTrashed
            case .favorites: included = note.isFavorite && !note.isTrashed
            case .notebook(let id): included = note.notebookID == id && !note.isTrashed
            case .stack: included = stackMembers.contains(note.notebookID) && !note.isTrashed
            case .tag(let tag): included = note.tags.contains(tag) && !note.isTrashed
            case .smart(let id):
                if let saved = savedSearches.first(where: { $0.id == id }) {
                    included = !note.isTrashed && matches(note, title: saved.title, tag: saved.tag,
                        notebookID: saved.notebookID, after: saved.modifiedAfter, before: saved.modifiedBefore)
                        && (saved.query.isEmpty || savedSearchMatches[id]?.contains(note.id) == true)
                } else { included = false }
            case .trash: included = note.isTrashed
            case .graph: included = !note.isTrashed
            }
            return included && matches(note, title: advancedTitle, tag: advancedTag, notebookID: advancedNotebookID, after: advancedAfter, before: advancedBefore)
                && (search.isEmpty || fullTextMatches.contains(note.id) || note.title.localizedCaseInsensitiveContains(search) || note.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) }))
        }
    }

    private func matches(_ note: NoteSummary, title: String, tag: String, notebookID: String?, after: Date?, before: Date?) -> Bool {
        (title.isEmpty || note.title.localizedCaseInsensitiveContains(title))
        && (tag.isEmpty || note.tags.contains { $0.localizedCaseInsensitiveContains(tag) })
        && (notebookID == nil || note.notebookID == notebookID)
        && (after == nil || note.modifiedAt >= after!)
        && (before == nil || note.modifiedAt < Calendar.current.date(byAdding: .day, value: 1, to: before!)!)
    }

    var tags: [String] { Array(Set(summaries.filter { !$0.isTrashed }.flatMap(\.tags))).sorted() }

    func searchChanged() {
        searchTask?.cancel()
        let query = search, repo = repository, generation = accountGeneration
        guard !query.isEmpty else { fullTextMatches = []; return }
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let ids = try await repo.searchNoteIDs(query)
                guard !Task.isCancelled, query == search, generation == accountGeneration else { return }
                fullTextMatches = ids
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }

    func session(for id: UUID, waitForContent: Bool = false) async -> EditorSession? {
        if let session = sessions[id] { return waitForContent ? await sessionWithContent(session) : session }
        let generation = accountGeneration
        do {
            guard let note = try await repository.note(id: id), generation == accountGeneration else { return nil }
            if let existing = sessions[id] { return waitForContent ? await sessionWithContent(existing) : existing }
            let session = EditorSession(note: note, workspaceGeneration: generation)
            sessions[id] = session
            if note.remoteID != nil, note.mode != .locked, (!note.hasRemoteContent || note.listedVersion != nil && note.listedVersion != note.serverVersion), isConnected {
                Task { [weak self, weak session] in
                    guard let self, let session else { return }
                    await self.fetchContent(for: session)
                }
            }
            return waitForContent ? await sessionWithContent(session) : session
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    /// Metadata mutations need a complete base document before they can be saved.
    private func sessionWithContent(_ session: EditorSession) async -> EditorSession? {
        if session.downloadTask != nil || (session.note.remoteID != nil && session.note.mode != .locked &&
            (!session.note.hasRemoteContent || session.note.listedVersion != nil && session.note.listedVersion != session.note.serverVersion)) {
            await fetchContent(for: session)
        }
        guard session.workspaceGeneration == accountGeneration, sessions[session.id] === session else { return nil }
        guard session.note.remoteID == nil || session.note.hasRemoteContent || session.note.mode == .locked else {
            errorMessage = AppLocalization.syncErrorMessage(session.note.lastError) ?? appText("Download the note body from the NAS before editing.")
            return nil
        }
        return session
    }

    func newNote(notebookID: String? = nil) async -> UUID? {
        let generation = accountGeneration
        do {
            let destination = try destinationNotebook(preferred: notebookID)
            let note = try await repository.save(NoteRecord(title: appText("New Note"), notebookID: destination),
                                                 enqueue: isNASNotebook(destination))
            guard generation == accountGeneration else { return nil }
            sessions[note.id] = EditorSession(note: note, workspaceGeneration: generation)
            applyLocalNote(note)
            scheduleLocalReload()
            scheduleUpload()
            logEvent(.noteCreated, noteID: note.id, notebookID: destination)
            return note.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func edit(_ session: EditorSession, registerUndo: Bool = false, mutate: (inout NoteRecord) -> Void) {
        guard session.workspaceGeneration == accountGeneration, sessions[session.id] === session else { return }
        guard session.note.remoteID == nil || session.note.hasRemoteContent || session.note.mode == .locked else {
            errorMessage = appText("Download the note body from the NAS before editing.")
            return
        }
        guard !deletingNoteIDs.contains(session.id) else { return }
        guard !deletingNotebookIDs.contains(session.note.notebookID) else { errorMessage = appText("Wait for the notebook deletion to finish."); return }
        if registerUndo {
            let previous = session.note
            session.undoManager.registerUndo(withTarget: session) { [weak self] target in
                self?.edit(target, registerUndo: true) { note in
                    note.title = previous.title; note.markdown = previous.markdown; note.blocks = previous.blocks
                    note.mode = previous.mode; note.attachments = previous.attachments; note.tags = previous.tags
                    note.originalHTML = previous.originalHTML
                    note.notebookID = previous.notebookID; note.isFavorite = previous.isFavorite; note.isTrashed = previous.isTrashed
                }
            }
        }
        mutate(&session.note)
        session.editGeneration += 1
        session.saveError = nil
        session.saveTask?.cancel()
        session.saveTask = Task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await save(session)
        }
    }

    func save(_ session: EditorSession, enqueue: Bool = true) async {
        guard session.workspaceGeneration == accountGeneration, sessions[session.id] === session else { return }
        guard session.editGeneration != session.savedGeneration else { return }
        let generation = session.editGeneration, account = accountGeneration
        let snapshot = session.note, repo = repository
        session.isSaving = true
        do {
            let saved = try await repo.save(snapshot, enqueue: enqueue && isNASNotebook(snapshot.notebookID))
            guard account == accountGeneration else { return }
            session.savedGeneration = generation
            if session.editGeneration == generation { session.note = saved; session.isSaving = false }
            applyLocalNote(saved)
            scheduleLocalReload()
            if enqueue { scheduleUpload() }
            logEvent(.noteSaved, noteID: session.id, notebookID: saved.notebookID, fields: ["revision": String(saved.revision), "state": saved.syncState.rawValue])
        } catch {
            session.isSaving = false; session.saveError = error.localizedDescription
            logEvent(.noteSaveFailed, noteID: session.id, error: error)
        }
    }

    func flush() async {
        for session in Array(sessions.values) {
            session.saveTask?.cancel()
            await save(session)
        }
    }

    func convert(_ session: EditorSession) async {
        let html = session.note.originalHTML
        let converted = await Task.detached(priority: .userInitiated) { MarkdownPipeline.importHTML(html) }.value
        guard converted.safeToEdit else { errorMessage = appText("Some formatting cannot be separated safely. View or export the original instead."); return }
        session.note.markdown = converted.markdown; session.note.blocks = converted.blocks; session.note.mode = .markdown
        session.editGeneration += 1
        await save(session, enqueue: false)
    }

    func toggleFavorite(_ session: EditorSession) { edit(session) { $0.isFavorite.toggle() } }
    func toggleTrash(_ session: EditorSession) { edit(session) { $0.isTrashed.toggle() } }

    func useServerConflict(_ session: EditorSession) async {
        guard let html = session.note.conflictSnapshot?.html ?? session.note.conflictHTML else { return }
        // Saving keeps a revision of the local draft before adopting the server.
        await save(session)
        do { try await resolveSyncAttempt(for: session) } catch { errorMessage = error.localizedDescription; return }
        var note = session.note
        note.originalHTML = html; note.baseHTML = html; note.serverVersion = note.conflictSnapshot?.version ?? note.conflictVersion
        if let snapshot = note.conflictSnapshot { note.attachments = snapshot.attachments }
        note.conflictHTML = nil; note.conflictVersion = nil; note.conflictSnapshot = nil; note.mode = .original
        note.markdown = ""; note.blocks = []; note.syncState = .synced
        session.note = note; session.editGeneration += 1
        await save(session, enqueue: false)
        do { try await repository.acknowledge(noteID: note.id, revision: session.note.revision, serverVersion: note.serverVersion ?? "") } catch { errorMessage = error.localizedDescription }
    }

    func keepLocalConflict(_ session: EditorSession) async {
        // Preserve the other side as its own local note before resolving the comparison.
        guard let html = session.note.conflictSnapshot?.html ?? session.note.conflictHTML else { return }
        var copy = NoteRecord(title: session.note.title + appText(" · Server Copy"), mode: .original)
        copy.originalHTML = html
        copy.attachments = session.note.conflictSnapshot?.attachments ?? []
        do {
            _ = try await repository.save(copy, enqueue: false)
            try await resolveSyncAttempt(for: session)
            edit(session) { note in
                note.serverVersion = note.conflictSnapshot?.version ?? note.conflictVersion; note.baseHTML = html
                note.conflictHTML = nil; note.conflictVersion = nil; note.conflictSnapshot = nil
            }
            await save(session)
        } catch { errorMessage = error.localizedDescription }
    }

    func addAttachment(to session: EditorSession, url: URL) async {
        let generation = accountGeneration, store = attachments
        do {
            let attachment = try await store.importFile(url)
            guard generation == accountGeneration, session.workspaceGeneration == generation else { return }
            insertAttachment(attachment, into: session)
        } catch { errorMessage = error.localizedDescription }
    }
    func addImage(to session: EditorSession, data: Data) async {
        let generation = accountGeneration, store = attachments
        do {
            let attachment = try await store.importData(data, name: appText("Pasted Image.png"))
            guard generation == accountGeneration, session.workspaceGeneration == generation else { return }
            insertAttachment(attachment, into: session)
        }
        catch { errorMessage = error.localizedDescription }
    }
    private func insertAttachment(_ attachment: NoteAttachment, into session: EditorSession) {
        edit(session) { note in
            note.attachments.append(attachment)
            let image = ["png","jpg","jpeg","gif","webp","heic","tiff"].contains((attachment.name as NSString).pathExtension.lowercased())
            let label = attachment.name.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            if note.mode == .original {
                let escaped = attachment.name.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                note.originalHTML += image ? "<p><img src=\"\(attachment.reference)\" alt=\"\(escaped)\"></p>"
                    : "<p><a href=\"\(attachment.reference)\">\(escaped)</a></p>"
            } else { note.markdown += "\n\n\(image ? "!" : "")[\(label)](\(attachment.reference))\n" }
        }
    }

}
