import Foundation
import CSQLite
import SwiftSoup

public struct RepositoryError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The actor owns its SQLite connection. No network request runs in a transaction.
public actor NoteRepository {
    private let database: OpaquePointer
    private let directory: URL
    private let diagnostics: DatabaseMaintenance.Observer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL, diagnostics: @escaping DatabaseMaintenance.Observer = { _ in }) throws {
        self.diagnostics = diagnostics
        let openStarted = ProcessInfo.processInfo.systemUptime
        var opened = false
        diagnostics(.init(operation: .open, phase: .started, metrics: [:]))
        defer { diagnostics(.init(operation: .open, phase: opened ? .completed : .failed, metrics: ["duration_ms": Int64((ProcessInfo.processInfo.systemUptime - openStarted) * 1000)])) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseFile = directory.appendingPathComponent("notes.sqlite3")
        // A missing database with existing backups indicates lost local state.
        // Offer recovery rather than silently creating an empty library.
        if !FileManager.default.fileExists(atPath: databaseFile.path),
           !DatabaseMaintenance.snapshots(in: directory).isEmpty {
            throw RepositoryError(message: coreText("The local database file is missing. Select an automatic backup to recover it."))
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseFile.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw RepositoryError(message: coreText("Could not open the local storage."))
        }
        database = handle
        self.directory = directory
        sqlite3_busy_timeout(handle, 5000)
        // Detect damaged existing files before schema migrations can write to them.
        do { try DatabaseMaintenance.traced(.integrity, observer: diagnostics) { try DatabaseMaintenance.checkIntegrity(handle) } }
        catch { sqlite3_close(handle); throw error }
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, remote_id TEXT UNIQUE, summary BLOB NOT NULL, body BLOB NOT NULL, modified REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS revisions (id TEXT PRIMARY KEY, note_id TEXT NOT NULL, number INTEGER NOT NULL, payload BLOB NOT NULL, UNIQUE(note_id, number));
        CREATE TABLE IF NOT EXISTS operations (note_id TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS notebooks (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_attempts (note_id TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS search_documents (id TEXT PRIMARY KEY, text TEXT NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(text, tokenize='trigram');
        CREATE TRIGGER IF NOT EXISTS fts_insert AFTER INSERT ON search_documents BEGIN INSERT INTO search_fts(rowid,text) VALUES (NEW.rowid,NEW.text); END;
        CREATE TRIGGER IF NOT EXISTS fts_update AFTER UPDATE ON search_documents BEGIN DELETE FROM search_fts WHERE rowid=OLD.rowid; INSERT INTO search_fts(rowid,text) VALUES (NEW.rowid,NEW.text); END;
        CREATE TRIGGER IF NOT EXISTS fts_delete AFTER DELETE ON search_documents BEGIN DELETE FROM search_fts WHERE rowid=OLD.rowid; END;
        CREATE TABLE IF NOT EXISTS saved_searches (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS note_links (source_id TEXT NOT NULL, destination TEXT NOT NULL, target_id TEXT, PRIMARY KEY(source_id,destination));
        CREATE TABLE IF NOT EXISTS note_links_indexed (id TEXT PRIMARY KEY);
        CREATE INDEX IF NOT EXISTS note_links_target ON note_links(target_id);
        CREATE TABLE IF NOT EXISTS deleted_notes (local_id TEXT PRIMARY KEY, remote_id TEXT UNIQUE);
        CREATE TRIGGER IF NOT EXISTS remove_search_document AFTER DELETE ON notes BEGIN DELETE FROM search_documents WHERE id=OLD.id; END;
        CREATE TRIGGER IF NOT EXISTS remove_note_links AFTER DELETE ON notes BEGIN DELETE FROM note_links WHERE source_id=OLD.id; END;
        CREATE TRIGGER IF NOT EXISTS remove_note_links_indexed AFTER DELETE ON notes BEGIN DELETE FROM note_links_indexed WHERE id=OLD.id; END;
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw RepositoryError(message: coreText("Could not initialize the local storage."))
        }
        do {
            // Repair legacy FTS rows before any backfill can reuse an orphaned rowid.
            // A forced snapshot is created before dropping the old FTS table.
            let repaired = try Self.repairSearchIndexIfNeeded(database: handle, directory: directory, diagnostics: diagnostics)
            try Self.backfillSearch(database: handle)
            try Self.backfillLinks(database: handle)
            try Self.compactIfNeeded(database: handle, directory: directory, repaired: repaired, diagnostics: diagnostics)
        }
        catch { sqlite3_close(handle); throw error }
        opened = true
    }

    deinit { sqlite3_close(database) }

    /// Keeps one coherent DB snapshot per interval, including queued NAS writes and all revisions.
    @discardableResult public func backupIfNeeded(force: Bool = false) throws -> URL? {
        try DatabaseMaintenance.snapshot(from: database, in: directory, force: force, observer: diagnostics)
    }

    /// Consistent aggregate read through the actor's WAL-aware connection.
    /// Never exports the database, schema SQL, identifiers, or document payloads.
    public func diagnosticReport() throws -> DatabaseDiagnosticReport {
        try execute("BEGIN")
        defer { try? execute("ROLLBACK") }
        func scalar(_ sql: String) throws -> Int64 {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int64(statement, 0)
        }
        var counts: [String: Int64] = [:]
        for table in ["notes", "revisions", "operations", "sync_attempts", "notebooks", "search_documents", "search_fts", "note_links"] {
            counts[table] = try scalar("SELECT count(*) FROM \(table)")
        }
        var states: [String: Int64] = [:]
        for state in ["local", "synced", "failed", "conflict", "uncertain"] {
            states[state] = try scalar("SELECT count(*) FROM notes WHERE json_extract(CAST(summary AS TEXT),'$.syncState')='\(state)'")
        }
        let backups = DatabaseMaintenance.snapshots(in: directory)
        return try DatabaseDiagnosticReport(sqliteVersion: String(cString: sqlite3_libversion()),
            schemaVersion: scalar("PRAGMA user_version"),
            integrityOK: (try? DatabaseMaintenance.checkIntegrity(database)) != nil,
            pageCount: scalar("PRAGMA page_count"), pageSize: scalar("PRAGMA page_size"),
            freePages: scalar("PRAGMA freelist_count"), tableCounts: counts, syncStateCounts: states,
            orphanedSearchRows: scalar("SELECT count(*) FROM search_fts f LEFT JOIN search_documents d ON f.rowid=d.rowid WHERE d.rowid IS NULL"),
            missingSearchRows: scalar("SELECT count(*) FROM search_documents d LEFT JOIN search_fts f ON f.rowid=d.rowid WHERE f.rowid IS NULL"),
            mismatchedSearchRows: scalar("SELECT count(*) FROM search_documents d JOIN search_fts f ON f.rowid=d.rowid WHERE f.text!=d.text"),
            backupCount: backups.count, backupBytes: backups.reduce(0) { $0 + $1.size })
    }

    public func listNotes(search: String = "") throws -> [NoteSummary] {
        // A list request reads summaries, never every document body.
        let values: [NoteSummary] = try blobs("SELECT summary FROM notes ORDER BY modified DESC").map { try decoder.decode(NoteSummary.self, from: $0) }
        guard !search.isEmpty else { return values }
        return values.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) }) || $0.excerpt.localizedCaseInsensitiveContains(search) }
    }

    public func searchNoteIDs(_ query: String) throws -> Set<UUID> {
        guard !query.isEmpty else { return [] }
        let normalized = Self.normalized(query)
        // FTS5 trigram handles Korean substrings and ordinary literals of >= 3 characters.
        // Short terms and tokens the FTS tokenizer cannot match retain exact substring semantics.
        var results: [Data] = []
        if normalized.count >= 3 {
            let phrase = "\"" + normalized.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            results = try blobs("SELECT CAST(d.id AS BLOB) FROM search_fts JOIN search_documents d ON d.rowid=search_fts.rowid WHERE search_fts MATCH ? AND instr(d.text,?)>0", strings: [phrase, normalized])
        }
        // FTS token boundaries can differ from SQLite substring matching for
        // Unicode and punctuation. Include the exact scan to avoid missing notes.
        results += try blobs("SELECT CAST(id AS BLOB) FROM search_documents WHERE instr(text,?)>0", strings: [normalized])
        return Set(results
            .compactMap { UUID(uuidString: String(decoding: $0, as: UTF8.self)) })
    }

    public func savedSearches() throws -> [SavedSearch] {
        try blobs("SELECT payload FROM saved_searches ORDER BY id").map { try decoder.decode(SavedSearch.self, from: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func saveSearch(_ search: SavedSearch) throws {
        try execute("INSERT OR REPLACE INTO saved_searches VALUES (?,?)", values: [.text(search.id.uuidString), .data(try encoder.encode(search))])
    }

    public func deleteSearch(id: UUID) throws {
        try execute("DELETE FROM saved_searches WHERE id=?", values: [.text(id.uuidString)])
    }

    /// A duplicate filename is ambiguous: never silently open the wrong note.
    public func resolveLink(_ destination: String, from sourceID: UUID) throws -> UUID {
        if let documentID = InternalNoteLinks.documentID(for: destination) {
            // The local UUID remains a valid alias after importing a NAS source
            // envelope (whose documentID may differ from the cache UUID).
            let matches = try listNotes().filter {
                !$0.isTrashed && ($0.id == documentID || $0.sourceDocumentID == documentID)
            }
            guard matches.count == 1, let target = matches.first else {
                throw RepositoryError(message: coreText("The linked document could not be found or its identifier is duplicated."))
            }
            return target.id
        }
        if let remoteID = InternalNoteLinks.remoteID(for: destination) {
            let matches = try listNotes().filter { !$0.isTrashed && $0.remoteID == remoteID }
            guard matches.count == 1, let target = matches.first else {
                throw RepositoryError(message: coreText("The NAS document could not be found or its server ID is duplicated."))
            }
            return target.id
        }
        guard let title = InternalNoteLinks.title(for: destination) else { throw RepositoryError(message: coreText("The note link format is invalid.")) }
        let recorded = try blobs("SELECT CAST(target_id AS BLOB) FROM note_links WHERE source_id=? AND destination=? AND target_id IS NOT NULL", strings: [sourceID.uuidString, destination])
        if let id = recorded.first.flatMap({ UUID(uuidString: String(decoding: $0, as: UTF8.self)) }) {
            guard let target = try note(id: id), !target.isTrashed else {
                throw RepositoryError(message: coreText("The linked note was deleted or is in the Trash: %@", "\(title)"))
            }
            return id
        }
        let matches = try listNotes().filter { !$0.isTrashed && $0.title.precomposedStringWithCanonicalMapping == title.precomposedStringWithCanonicalMapping }
        guard matches.count == 1, let id = matches.first?.id else {
            throw RepositoryError(message: matches.isEmpty ? coreText("The linked note could not be found: %@", "\(title)") : coreText("The link is ambiguous because multiple notes are named “%@”.", "\(title)"))
        }
        try execute("UPDATE note_links SET target_id=? WHERE source_id=? AND destination=?", values: [.text(id.uuidString), .text(sourceID.uuidString), .text(destination)])
        return id
    }

    public func backlinks(to id: UUID) throws -> [NoteSummary] {
        guard let target = try note(id: id), !target.isTrashed else { return [] }
        let active = try listNotes().filter { !$0.isTrashed }
        let documentIDs = Set([target.id, target.sourceDocumentID].compactMap { $0 })
        let title = target.title.precomposedStringWithCanonicalMapping
        let unique = active.filter { $0.title.precomposedStringWithCanonicalMapping == title }.count == 1
        let uniqueDocuments = documentIDs.filter { alias in
            active.filter { $0.id == alias || $0.sourceDocumentID == alias }.count == 1
        }
        let uniqueRemote = target.remoteID.map { id in active.filter { $0.remoteID == id }.count == 1 } ?? false
        let known = try blobs("SELECT DISTINCT CAST(source_id AS BLOB) FROM note_links WHERE target_id=?", strings: [id.uuidString])
        // Decode URL-escaped and Unicode-normalized filenames too.
        let byName: [Data] = try linkRows().compactMap { source, destination, linked in
            if let alias = InternalNoteLinks.documentID(for: destination), uniqueDocuments.contains(alias) {
                return Data(source.utf8)
            }
            if uniqueRemote, let remoteID = target.remoteID, InternalNoteLinks.remoteID(for: destination) == remoteID {
                return Data(source.utf8)
            }
            if unique && linked == nil && InternalNoteLinks.title(for: destination)?.precomposedStringWithCanonicalMapping == title {
                return Data(source.utf8)
            }
            return nil
        }
        let ids = Set((known + byName).compactMap { UUID(uuidString: String(decoding: $0, as: UTF8.self)) })
        return active.filter { ids.contains($0.id) }
    }

    /// Index-only graph read. Previously confirmed UUID links survive renames.
    /// Unresolved filenames are used only when exactly one active title matches.
    public func noteGraph() throws -> NoteGraph {
        try noteGraph(summaries: listNotes())
    }

    /// Reuse a caller's snapshot to avoid decoding all note summaries twice
    /// during a library refresh.
    public func noteGraph(summaries: [NoteSummary]) throws -> NoteGraph {
        let active = summaries.filter { !$0.isTrashed }
        let nodes = active.map { NoteGraphNode(id: $0.id, title: $0.title, notebookID: $0.notebookID, tags: $0.tags) }
        let ids = Set(active.map(\.id))
        let titles = Dictionary(grouping: active, by: { $0.title.precomposedStringWithCanonicalMapping })
        // Index every local/document alias, failing closed on collisions.
        var documents: [UUID: Set<UUID>] = [:]
        for note in active {
            documents[note.id, default: []].insert(note.id)
            if let source = note.sourceDocumentID { documents[source, default: []].insert(note.id) }
        }
        let remoteIDs = Dictionary(grouping: active.filter { $0.remoteID != nil }, by: { $0.remoteID! })
        var edges: Set<NoteGraphEdge> = []
        for (source, destination, linked) in try linkRows() {
            guard let from = UUID(uuidString: source), ids.contains(from) else { continue }
            let target: UUID?
            if let documentID = InternalNoteLinks.documentID(for: destination) {
                let matches = documents[documentID] ?? []
                target = matches.count == 1 ? matches.first : nil
            } else if let remoteID = InternalNoteLinks.remoteID(for: destination) {
                let matches = remoteIDs[remoteID] ?? []
                target = matches.count == 1 ? matches[0].id : nil
            } else if let linked { target = UUID(uuidString: linked) }
            else if let title = InternalNoteLinks.title(for: destination)?.precomposedStringWithCanonicalMapping,
                    let matches = titles[title], matches.count == 1 {
                target = matches[0].id
            } else { target = nil }
            if let target, ids.contains(target) { edges.insert(NoteGraphEdge(sourceID: from, targetID: target)) }
        }
        return NoteGraph(nodes: nodes, edges: edges.sorted {
            ($0.sourceID.uuidString, $0.targetID.uuidString) < ($1.sourceID.uuidString, $1.targetID.uuidString)
        })
    }

    public func offlineCandidates() throws -> [NoteSummary] {
        try blobs("""
            SELECT summary FROM notes WHERE remote_id IS NOT NULL
            AND json_extract(CAST(body AS TEXT),'$.mode') != 'locked'
            AND (json_extract(CAST(body AS TEXT),'$.hasRemoteContent') = 0
                OR COALESCE(json_extract(CAST(body AS TEXT),'$.serverVersion'),'') != COALESCE(json_extract(CAST(body AS TEXT),'$.listedVersion'),''))
            ORDER BY modified DESC
            """).map { try decoder.decode(NoteSummary.self, from: $0) }
    }

    public func note(id: UUID) throws -> NoteRecord? {
        try blobs("SELECT body FROM notes WHERE id=?", strings: [id.uuidString]).first.map { try decoder.decode(NoteRecord.self, from: $0) }
    }

    public func note(remoteID: String) throws -> NoteRecord? {
        try blobs("SELECT body FROM notes WHERE remote_id=?", strings: [remoteID]).first.map { try decoder.decode(NoteRecord.self, from: $0) }
    }

    @discardableResult public func save(_ input: NoteRecord, enqueue: Bool = true) throws -> NoteRecord {
        guard try blobs("SELECT CAST(local_id AS BLOB) FROM deleted_notes WHERE local_id=?", strings: [input.id.uuidString]).isEmpty else { throw RepositoryError(message: coreText("Permanently deleted notes cannot be saved again.")) }
        if let id = input.remoteID, try isPermanentlyDeleted(remoteID: id) { throw RepositoryError(message: coreText("Permanently deleted notes cannot be saved again.")) }
        var result = input
        let current = try note(id: input.id)
        if let current {
            result.createdAt = current.createdAt ?? input.createdAt ?? current.modifiedAt
            // Text edits come from the editor; NAS identity and acknowledged
            // versions come from the repository. A delayed save must not undo
            // a concurrent upload completion or turn an update into a create.
            result.remoteID = current.remoteID ?? input.remoteID
            result.sourceDocumentID = current.sourceDocumentID ?? input.sourceDocumentID
            let explicitRebase = current.conflictHTML != nil && input.conflictHTML == nil
                && input.serverVersion == current.conflictVersion
            if !explicitRebase && current.remoteID != nil {
                result.serverVersion = current.serverVersion; result.listedVersion = current.listedVersion
                result.baseHTML = current.baseHTML
                // In original mode HTML is editor content, just like Markdown.
                // An undo back to baseHTML is still a deliberate body edit.
                if input.mode != .original { result.originalHTML = current.originalHTML }
                result.hasRemoteContent = current.hasRemoteContent
                result.conflictHTML = current.conflictHTML; result.conflictVersion = current.conflictVersion; result.conflictSnapshot = current.conflictSnapshot
            }
            for index in result.attachments.indices {
                if let saved = current.attachments.first(where: { $0.id == result.attachments[index].id }), saved.remoteID != nil {
                    result.attachments[index].remoteID = saved.remoteID; result.attachments[index].remoteReference = saved.remoteReference
                }
            }
        }
        result.revision = (current?.revision ?? 0) + 1
        result.modifiedAt = Date()
        result.syncState = enqueue ? (result.conflictHTML == nil ? .pending : .conflict) : result.syncState
        result.lastError = nil
        let revision = NoteRevision(id: UUID(), noteID: result.id, number: result.revision, savedAt: result.modifiedAt, note: result)
        try transaction {
            try write(result)
            try execute("INSERT INTO revisions VALUES (?,?,?,?)", values: [.text(revision.id.uuidString), .text(result.id.uuidString), .int(result.revision), .data(try encoder.encode(revision))])
            if enqueue {
                let operation = PendingOperation(id: UUID(), noteID: result.id, revision: result.revision, baseVersion: result.serverVersion, state: result.conflictHTML == nil ? .pending : .conflict, attempts: 0, nextAttemptAt: Date())
                try writeOperation(operation)
            }
        }
        return result
    }

    @discardableResult public func mergeRemote(_ remote: NoteRecord, ifUnchangedFrom baseline: NoteRecord? = nil) throws -> NoteRecord {
        guard let remoteID = remote.remoteID else { throw RepositoryError(message: coreText("The server note ID is missing.")) }
        guard try !isPermanentlyDeleted(remoteID: remoteID) else { throw RepositoryError(message: coreText("This note was permanently deleted.")) }
        if var local = try note(remoteID: remoteID) {
            if let baseline, local.id != baseline.id || local.serverVersion != baseline.serverVersion { return local }
            if local.serverVersion == remote.serverVersion && local.hasRemoteContent { return local }
            let operation = try pendingOperations().first(where: { $0.noteID == local.id })
            if operation != nil {
                // Our own staged/body upload can advance NAS version before
                // source publication. Only the sync journal can reconcile it.
                if try syncAttempts().contains(where: { $0.note.id == local.id }) { return local }
                local.conflictHTML = remote.originalHTML
                local.conflictVersion = remote.serverVersion
                local.conflictSnapshot = RemoteConflictSnapshot(
                    html: remote.originalHTML,
                    version: remote.serverVersion,
                    attachments: remote.attachments
                )
                local.syncState = .conflict
                local.lastError = coreText("The official app changed this note. Review both versions.")
                var conflicted = operation!
                conflicted.state = .conflict
                try transaction { try write(local); try writeOperation(conflicted) }
                return local
            }
            var updated = remote
            updated.id = local.id
            updated.createdAt = remote.createdAt ?? local.createdAt ?? local.modifiedAt
            updated.revision = local.revision
            updated.listedVersion = remote.listedVersion ?? remote.serverVersion
            updated.syncState = .synced
            updated.baseHTML = remote.originalHTML
            try write(updated)
            return updated
        }
        var imported = remote
        imported.listedVersion = remote.listedVersion ?? remote.serverVersion
        imported.syncState = .synced
        imported.baseHTML = remote.originalHTML
        try write(imported)
        return imported
    }

    /// Listing metadata never advances the version of a body that has not been downloaded.
    public func observeRemote(_ remote: NoteRecord) throws {
        guard let remoteID = remote.remoteID else { throw RepositoryError(message: coreText("The server note ID is missing.")) }
        if try isPermanentlyDeleted(remoteID: remoteID) { return }
        if var local = try note(remoteID: remoteID) {
            local.listedVersion = remote.listedVersion ?? remote.serverVersion
            // NAS metadata can provide the original date after an older local cache was created.
            local.createdAt = remote.createdAt ?? local.createdAt
            let pending = try pendingOperations().contains(where: { $0.noteID == local.id })
            if !pending {
                local.title = remote.title; local.notebookID = remote.notebookID; local.tags = remote.tags
                local.isFavorite = remote.isFavorite; local.isTrashed = remote.isTrashed; local.modifiedAt = remote.modifiedAt
            }
            try write(local)
        } else {
            var shell = remote
            shell.hasRemoteContent = shell.mode == .locked
            shell.listedVersion = remote.listedVersion ?? remote.serverVersion
            shell.serverVersion = nil
            shell.syncState = .local
            try write(shell)
        }
    }

    public func revisions(noteID: UUID) throws -> [NoteRevision] {
        try blobs("SELECT payload FROM revisions WHERE note_id=? ORDER BY number DESC", strings: [noteID.uuidString]).map { try decoder.decode(NoteRevision.self, from: $0) }
    }

    public func pendingOperations() throws -> [PendingOperation] {
        try blobs("SELECT payload FROM operations").map { try decoder.decode(PendingOperation.self, from: $0) }.sorted { $0.nextAttemptAt < $1.nextAttemptAt }
    }

    public func syncAttempts() throws -> [SyncAttempt] {
        try blobs("SELECT payload FROM sync_attempts").map { try decoder.decode(SyncAttempt.self, from: $0) }
    }
    public func beginSync(_ attempt: SyncAttempt) throws {
        try execute("INSERT OR REPLACE INTO sync_attempts VALUES (?,?)", values: [.text(attempt.note.id.uuidString), .data(try encoder.encode(attempt))])
    }
    public func discardAttempt(noteID: UUID) throws {
        try execute("DELETE FROM sync_attempts WHERE note_id=?", values: [.text(noteID.uuidString)])
    }
    public func restoreRetryableAfterNotApplied(noteID: UUID) throws {
        guard var operation = try pendingOperations().first(where: { $0.noteID == noteID }),
              var note = try note(id: noteID) else {
            try discardAttempt(noteID: noteID)
            return
        }
        operation.state = .pending
        operation.error = nil
        operation.nextAttemptAt = Date()
        note.syncState = note.conflictHTML == nil ? .pending : .conflict
        note.lastError = nil
        try transaction {
            try writeOperation(operation)
            try write(note)
            try execute("DELETE FROM sync_attempts WHERE note_id=?", values: [.text(noteID.uuidString)])
        }
    }
    public func completeSync(_ attempt: SyncAttempt, snapshot: SyncRemoteSnapshot) throws {
        guard var current = try note(id: attempt.note.id) else { return }
        // A list refresh after a lost create response may have imported a shell
        // with the same remote ID. Only an untouched read cache can be folded.
        let duplicate = try note(remoteID: snapshot.remoteID)
        if let duplicate, duplicate.id != current.id {
            guard duplicate.revision == 0, try !pendingOperations().contains(where: { $0.noteID == duplicate.id }) else {
                throw RepositoryError(message: coreText("Another local edit exists for the same NAS note. The edits cannot be merged automatically."))
            }
        }
        current.remoteID = snapshot.remoteID; current.serverVersion = snapshot.version
        current.listedVersion = snapshot.version
        let sameRevision = current.revision == attempt.note.revision
        current.baseHTML = snapshot.html
        if sameRevision || current.mode != .original { current.originalHTML = snapshot.html }
        current.hasRemoteContent = true
        if let source = snapshot.source, let envelope = try? SourceEnvelope.decode(source) { current.sourceDocumentID = envelope.documentID }
        var operation = try pendingOperations().first(where: { $0.noteID == current.id })
        if current.conflictHTML == snapshot.html,
           try syncAttempts().contains(where: { $0.operation.id == attempt.operation.id }) {
            current.conflictHTML = nil; current.conflictVersion = nil; current.conflictSnapshot = nil
        }
        current.syncState = current.conflictHTML != nil ? .conflict : sameRevision ? .synced : .pending
        current.lastError = nil
        if !sameRevision {
            operation?.baseVersion = snapshot.version
            if current.conflictHTML == nil { operation?.state = .pending; operation?.error = nil; operation?.nextAttemptAt = Date() }
        }
        if let assets = snapshot.attachments {
            if sameRevision { current.attachments = assets }
            else {
                let removed = Set(snapshot.removedAttachmentIDs ?? [])
                current.attachments.removeAll { $0.remoteID.map(removed.contains) ?? false }
                for index in current.attachments.indices {
                    if let remote = assets.first(where: { $0.id == current.attachments[index].id }) {
                        current.attachments[index].remoteID = remote.remoteID
                        current.attachments[index].remoteReference = remote.remoteReference
                    }
                }
            }
        }
        try transaction {
            if let duplicate, duplicate.id != current.id { try execute("DELETE FROM notes WHERE id=?", values: [.text(duplicate.id.uuidString)]) }
            try write(current)
            if sameRevision { try execute("DELETE FROM operations WHERE note_id=?", values: [.text(current.id.uuidString)]) }
            else if let operation { try writeOperation(operation) }
            try execute("DELETE FROM sync_attempts WHERE note_id=?", values: [.text(current.id.uuidString)])
        }
    }

    @discardableResult public func recordConflict(noteID: UUID, snapshot: SyncRemoteSnapshot) throws -> Bool {
        guard var note = try note(id: noteID), var operation = try pendingOperations().first(where: { $0.noteID == noteID }) else { return false }
        if note.remoteID == nil { note.remoteID = snapshot.remoteID }
        note.conflictHTML = snapshot.html; note.conflictVersion = snapshot.version
        note.conflictSnapshot = RemoteConflictSnapshot(html: snapshot.html, version: snapshot.version, attachments: snapshot.attachments ?? note.attachments)
        note.syncState = .conflict; note.lastError = coreText("The note changed on the NAS first. Review both versions.")
        operation.state = .conflict; operation.error = note.lastError
        try transaction {
            try write(note); try writeOperation(operation)
            try execute("DELETE FROM sync_attempts WHERE note_id=?", values: [.text(noteID.uuidString)])
        }
        return true
    }

    public func bindRemoteID(noteID: UUID, remoteID: String) throws {
        guard var current = try note(id: noteID) else { return }
        guard current.remoteID == nil || current.remoteID == remoteID else { throw RepositoryError(message: coreText("The NAS note association changed during upload.")) }
        if let duplicate = try note(remoteID: remoteID), duplicate.id != current.id {
            guard duplicate.revision == 0, try !pendingOperations().contains(where: { $0.noteID == duplicate.id }) else {
                throw RepositoryError(message: coreText("Another local edit exists for the same NAS note."))
            }
            try execute("DELETE FROM notes WHERE id=?", values: [.text(duplicate.id.uuidString)])
        }
        current.remoteID = remoteID
        try write(current)
    }

    public func acknowledge(noteID: UUID, revision: Int, serverVersion: String) throws {
        guard var note = try note(id: noteID) else { return }
        guard note.revision == revision else { return }
        note.serverVersion = serverVersion
        note.syncState = .synced
        note.lastError = nil
        try transaction {
            try write(note)
            try execute("DELETE FROM operations WHERE note_id=?", values: [.text(noteID.uuidString)])
        }
    }

    public func fail(noteID: UUID, message: String, uncertain: Bool = false) throws {
        guard var operation = try pendingOperations().first(where: { $0.noteID == noteID }), var note = try note(id: noteID) else { return }
        operation.attempts += 1
        operation.state = uncertain ? .uncertain : .failed
        operation.error = message
        operation.nextAttemptAt = Date().addingTimeInterval(min(3600, pow(2, Double(min(operation.attempts, 10))) * 5) + Double.random(in: 0...3))
        note.syncState = .failed
        note.lastError = message
        try transaction { try writeOperation(operation); try write(note) }
    }

    public func notebooks() throws -> [Notebook] {
        try blobs("SELECT payload FROM notebooks ORDER BY id").map { try decoder.decode(Notebook.self, from: $0) }
    }

    public func isPermanentlyDeleted(remoteID: String) throws -> Bool {
        try !blobs("SELECT CAST(local_id AS BLOB) FROM deleted_notes WHERE remote_id=?", strings: [remoteID]).isEmpty
    }

    /// Called only after NAS confirms absence. Shared cache files survive.
    public func purgeConfirmedTrash(noteID: UUID, remoteID: String) throws -> [NoteAttachment] {
        guard let note = try note(id: noteID), note.isTrashed, note.remoteID == remoteID else { throw RepositoryError(message: coreText("Only notes in the Trash can be permanently deleted.")) }
        guard try !pendingOperations().contains(where: { $0.noteID == noteID }),
              try !syncAttempts().contains(where: { $0.note.id == noteID }) else { throw RepositoryError(message: coreText("Review pending changes first.")) }
        let candidates = note.attachments + (try revisions(noteID: noteID).flatMap { $0.note.attachments })
        try transaction {
            try execute("INSERT OR REPLACE INTO deleted_notes VALUES (?,?)", values: [.text(noteID.uuidString), .text(remoteID)])
            for table in ["revisions", "operations", "sync_attempts"] { try execute("DELETE FROM \(table) WHERE note_id=?", values: [.text(noteID.uuidString)]) }
            try execute("DELETE FROM notes WHERE id=?", values: [.text(noteID.uuidString)])
        }
        let remainingNotes = try blobs("SELECT body FROM notes").map { try decoder.decode(NoteRecord.self, from: $0) }
        let remainingHistory = try blobs("SELECT payload FROM revisions").map { try decoder.decode(NoteRevision.self, from: $0) }
        let referenced = Set((remainingNotes.flatMap(\.attachments) + remainingHistory.flatMap { $0.note.attachments }).map(\.filename))
        var seen = Set<String>()
        return candidates.filter { !referenced.contains($0.filename) && seen.insert($0.filename).inserted }
    }

    public func setNotebooks(_ notebooks: [Notebook]) throws {
        try transaction {
            try execute("DELETE FROM notebooks")
            for notebook in notebooks {
                try execute("INSERT INTO notebooks VALUES (?,?)", values: [.text(notebook.id), .data(try encoder.encode(notebook))])
            }
        }
    }

    private func write(_ note: NoteRecord) throws {
        try execute("SAVEPOINT note_and_search")
        do {
            let previous = try self.note(id: note.id)
            if let previous, previous.title != note.title {
                // Preserve resolved local backlinks when a target is renamed.
                let others = try listNotes().filter { !$0.isTrashed && $0.id != note.id && $0.title == previous.title }
                if others.isEmpty {
                    // Resolve old name references before saving the renamed title.
                    for (source, destination, linked) in try linkRows() where linked == nil
                        && InternalNoteLinks.title(for: destination)?.precomposedStringWithCanonicalMapping == previous.title.precomposedStringWithCanonicalMapping {
                        try execute("UPDATE note_links SET target_id=? WHERE source_id=? AND destination=?", values: [.text(note.id.uuidString), .text(source), .text(destination)])
                    }
                }
            }
            try execute("INSERT INTO notes (id,remote_id,summary,body,modified) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET remote_id=excluded.remote_id,summary=excluded.summary,body=excluded.body,modified=excluded.modified", values: [.text(note.id.uuidString), note.remoteID.map(Value.text) ?? .null, .data(try encoder.encode(note.summary)), .data(try encoder.encode(note)), .double(note.modifiedAt.timeIntervalSince1970)])
            try execute("INSERT INTO search_documents (id,text) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET text=excluded.text WHERE search_documents.text != excluded.text", values: [.text(note.id.uuidString), .text(Self.searchText(note))])
            let destinations = note.mode == .markdown ? InternalNoteLinks.destinations(in: note.markdown) : []
            for destination in destinations {
                try execute("INSERT OR IGNORE INTO note_links(source_id,destination,target_id) VALUES (?,?,NULL)", values: [.text(note.id.uuidString), .text(destination)])
            }
            for old in try linkDestinations(from: note.id) where !destinations.contains(old) {
                try execute("DELETE FROM note_links WHERE source_id=? AND destination=?", values: [.text(note.id.uuidString), .text(old)])
            }
            try execute("INSERT OR IGNORE INTO note_links_indexed VALUES (?)", values: [.text(note.id.uuidString)])
            try execute("RELEASE note_and_search")
        } catch {
            try? execute("ROLLBACK TO note_and_search"); try? execute("RELEASE note_and_search")
            throw error
        }
    }
    private func linkDestinations(from id: UUID) throws -> [String] {
        try blobs("SELECT CAST(destination AS BLOB) FROM note_links WHERE source_id=?", strings: [id.uuidString]).map { String(decoding: $0, as: UTF8.self) }
    }
    private func linkRows() throws -> [(String, String, String?)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT source_id,destination,target_id FROM note_links", -1, &statement, nil) == SQLITE_OK else {
            throw RepositoryError(message: coreText("Could not read note links."))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [(String, String, String?)] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let source = sqlite3_column_text(statement, 0), let destination = sqlite3_column_text(statement, 1) {
                let linked = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                rows.append((String(cString: source), String(cString: destination), linked))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw RepositoryError(message: coreText("Could not read note links.")) }
        return rows
    }
    private static func backfillLinks(database: OpaquePointer) throws {
        var rows: OpaquePointer?, insert: OpaquePointer?, indexed: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT body FROM notes WHERE id NOT IN (SELECT id FROM note_links_indexed)", -1, &rows, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO note_links(source_id,destination,target_id) VALUES (?,?,NULL)", -1, &insert, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO note_links_indexed VALUES (?)", -1, &indexed, nil) == SQLITE_OK else {
            if let rows { sqlite3_finalize(rows) }; if let insert { sqlite3_finalize(insert) }; if let indexed { sqlite3_finalize(indexed) }
            throw RepositoryError(message: coreText("Could not prepare the note link index."))
        }
        defer { sqlite3_finalize(rows); sqlite3_finalize(insert); sqlite3_finalize(indexed) }
        let decoder = JSONDecoder()
        var status = sqlite3_step(rows)
        while status == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(rows, 0) {
                let note = try decoder.decode(NoteRecord.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(rows, 0))))
                if note.mode == .markdown {
                    for destination in InternalNoteLinks.destinations(in: note.markdown) {
                        sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                        sqlite3_bind_text(insert, 1, note.id.uuidString, -1, transient)
                        sqlite3_bind_text(insert, 2, destination, -1, transient)
                        guard sqlite3_step(insert) == SQLITE_DONE else { throw RepositoryError(message: coreText("Could not rebuild the note link index.")) }
                    }
                }
                sqlite3_reset(indexed); sqlite3_clear_bindings(indexed)
                sqlite3_bind_text(indexed, 1, note.id.uuidString, -1, transient)
                guard sqlite3_step(indexed) == SQLITE_DONE else { throw RepositoryError(message: coreText("Could not rebuild the note link records.")) }
            }
            status = sqlite3_step(rows)
        }
        guard status == SQLITE_DONE else { throw RepositoryError(message: coreText("Could not read the note link index.")) }
    }
    private static func normalized(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }
    private static func searchText(_ note: NoteRecord) -> String {
        let html = ([note.originalHTML] + note.activeBlocks.map(\.html)).joined(separator: "\n")
        let plain = (try? SwiftSoup.parseBodyFragment(html).text()) ?? ""
        return normalized(([note.title, note.markdown, plain] + note.tags).joined(separator: "\n"))
    }
    private static func backfillSearch(database: OpaquePointer) throws {
        var rows: OpaquePointer?, insert: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT body FROM notes WHERE id NOT IN (SELECT id FROM search_documents)", -1, &rows, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO search_documents VALUES (?,?)", -1, &insert, nil) == SQLITE_OK else {
            if let rows { sqlite3_finalize(rows) }; if let insert { sqlite3_finalize(insert) }
            throw RepositoryError(message: coreText("Could not prepare the search index."))
        }
        defer { sqlite3_finalize(rows); sqlite3_finalize(insert) }
        let decoder = JSONDecoder()
        var status = sqlite3_step(rows)
        while status == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(rows, 0) else { throw RepositoryError(message: coreText("Could not read the text for indexing.")) }
            let note = try decoder.decode(NoteRecord.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(rows, 0))))
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            sqlite3_bind_text(insert, 1, note.id.uuidString, -1, transient)
            sqlite3_bind_text(insert, 2, searchText(note), -1, transient)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw RepositoryError(message: coreText("Could not save the search index.")) }
            status = sqlite3_step(rows)
        }
        guard status == SQLITE_DONE else { throw RepositoryError(message: coreText("Could not recover the search index.")) }
    }

    /// Old INSERT OR REPLACE writes could leave FTS rows after their document rowid changed.
    /// Rebuild only the derived search table, after a verified whole-database backup.
    private static func repairSearchIndexIfNeeded(database: OpaquePointer, directory: URL, diagnostics: DatabaseMaintenance.Observer) throws -> Bool {
        func count(_ table: String) throws -> Int64 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT count(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError(message: coreText("Could not check the search index status."))
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw RepositoryError(message: coreText("Could not count search index entries."))
            }
            return sqlite3_column_int64(statement, 0)
        }

        // Equal counts can hide a missing document paired with an orphan, or
        // stale text at an otherwise valid rowid. Check content as well.
        var inconsistent = try count("search_fts") != count("search_documents")
        if !inconsistent {
            var statement: OpaquePointer?
            let mismatch = """
            SELECT EXISTS (
                SELECT 1 FROM search_fts AS f
                LEFT JOIN search_documents AS d ON d.rowid = f.rowid
                WHERE d.rowid IS NULL OR f.text != d.text
            ) OR EXISTS (
                SELECT 1 FROM search_documents AS d
                LEFT JOIN search_fts AS f ON f.rowid = d.rowid
                WHERE f.rowid IS NULL
            )
            """
            guard sqlite3_prepare_v2(database, mismatch, -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError(message: coreText("Could not inspect the search index associations."))
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw RepositoryError(message: coreText("Could not verify the search index associations."))
            }
            inconsistent = sqlite3_column_int(statement, 0) != 0
        }
        if !inconsistent {
            // FTS shadow rows may be present with correct text even when the
            // internal token index is damaged. SQLite quick_check does not
            // validate the FTS5 token index itself.
            let result = sqlite3_exec(database, "INSERT INTO search_fts(search_fts) VALUES('integrity-check')", nil, nil, nil)
            if result != SQLITE_OK {
                guard result & 0xff == SQLITE_CORRUPT else {
                    throw RepositoryError(message: coreText("Could not verify the internal full-text search index: %@", "\(String(cString: sqlite3_errmsg(database)))"))
                }
                inconsistent = true
            }
        }
        if inconsistent { try DatabaseMaintenance.snapshot(from: database, in: directory, force: true, observer: diagnostics) }
        let triggers = """
        DROP TRIGGER IF EXISTS fts_insert;
        DROP TRIGGER IF EXISTS fts_update;
        DROP TRIGGER IF EXISTS fts_delete;
        CREATE TRIGGER fts_insert AFTER INSERT ON search_documents
            BEGIN INSERT INTO search_fts(rowid,text) VALUES (NEW.rowid,NEW.text); END;
        CREATE TRIGGER fts_update AFTER UPDATE OF text ON search_documents
            WHEN OLD.text != NEW.text
            BEGIN DELETE FROM search_fts WHERE rowid=OLD.rowid;
                  INSERT INTO search_fts(rowid,text) VALUES (NEW.rowid,NEW.text); END;
        CREATE TRIGGER fts_delete AFTER DELETE ON search_documents
            BEGIN DELETE FROM search_fts WHERE rowid=OLD.rowid; END;
        """
        let sql: String
        if inconsistent {
            sql = """
            BEGIN IMMEDIATE;
            DROP TRIGGER IF EXISTS fts_insert;
            DROP TRIGGER IF EXISTS fts_update;
            DROP TRIGGER IF EXISTS fts_delete;
            DROP TABLE search_fts;
            CREATE VIRTUAL TABLE search_fts USING fts5(text, tokenize='trigram');
            \(triggers)
            INSERT INTO search_fts(rowid,text) SELECT rowid,text FROM search_documents;
            COMMIT;
            """
        } else {
            sql = "BEGIN IMMEDIATE; \(triggers) COMMIT;"
        }
        let needsRepair = inconsistent
        try DatabaseMaintenance.traced(.indexRepair, observer: { if needsRepair { diagnostics($0) } }, metrics: {
            guard needsRepair else { return [:] }
            return ["fts_rows": (try? count("search_fts")) ?? -1, "document_rows": (try? count("search_documents")) ?? -1]
        }) {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                throw RepositoryError(message: coreText("Could not rebuild the search index. The original data and backup were preserved."))
            }
        }
        return inconsistent
    }

    /// Retry space reclamation on a later launch if an earlier VACUUM failed or
    /// was interrupted after committing the index repair. Free pages remain a
    /// durable signal even though the rebuilt index is already consistent.
    private static func compactIfNeeded(database: OpaquePointer, directory: URL, repaired: Bool, diagnostics: DatabaseMaintenance.Observer) throws {
        func pragma(_ name: String) -> Int64 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
        }
        let free = pragma("freelist_count"), pages = pragma("page_count"), pageSize = pragma("page_size")
        // Avoid rewriting a healthy DB for small amounts of reusable space.
        let needsRetry = free * pageSize >= 4 * 1024 * 1024 && free >= pages / 4
        guard repaired || needsRetry else { return }
        if !repaired { try DatabaseMaintenance.snapshot(from: database, in: directory, force: true, observer: diagnostics) }
        // A busy reader or insufficient disk space must not prevent opening the
        // repaired library. The freelist above will trigger another attempt.
        try? DatabaseMaintenance.traced(.compaction, observer: diagnostics, metrics: {
            ["bytes": pragma("page_count") * pragma("page_size"), "free_pages": pragma("freelist_count")]
        }) {
            let code = sqlite3_exec(database, "VACUUM", nil, nil, nil)
            guard code == SQLITE_OK else { throw NSError(domain: "SQLite", code: Int(code)) }
            let checkpoint = sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            guard checkpoint == SQLITE_OK else { throw NSError(domain: "SQLite", code: Int(checkpoint)) }
        }
    }

    private func writeOperation(_ operation: PendingOperation) throws {
        try execute("INSERT OR REPLACE INTO operations VALUES (?,?)", values: [.text(operation.noteID.uuidString), .data(try encoder.encode(operation))])
    }
    private func transaction(_ block: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try block(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private enum Value { case text(String), data(Data), int(Int), double(Double), null }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func execute(_ sql: String, values: [Value] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .text(let text): code = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .data(let data): code = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
            case .int(let number): code = sqlite3_bind_int64(statement, index, Int64(number))
            case .double(let number): code = sqlite3_bind_double(statement, index, number)
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func blobs(_ sql: String, strings: [String] = []) throws -> [Data] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in strings.enumerated() { sqlite3_bind_text(statement, Int32(offset + 1), value, -1, Self.transient) }
        var results: [Data] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(statement, 0) { results.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))) }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return results
    }
    private func failure() -> RepositoryError { RepositoryError(message: coreText("Local save failed (SQLite %@). Check available disk space and file permissions.", "\(sqlite3_errcode(database))")) }
}
