import Foundation

public struct SyncRemoteSnapshot: Codable, Sendable {
    public var remoteID: String
    public var version: String
    public var html: String
    public var source: Data?
    public var summary: RemoteNoteSummary?
    public var attachments: [NoteAttachment]?
    public var removedAttachmentIDs: [String]?
    public init(remoteID: String, version: String, html: String, source: Data?, summary: RemoteNoteSummary? = nil,
                attachments: [NoteAttachment]? = nil, removedAttachmentIDs: [String]? = nil) {
        self.remoteID = remoteID; self.version = version; self.html = html; self.source = source
        self.summary = summary; self.attachments = attachments; self.removedAttachmentIDs = removedAttachmentIDs
    }
}
public struct SyncAttempt: Codable, Sendable {
    public var operation: PendingOperation
    public var note: NoteRecord
    public var html: String
    public var source: Data
}
public struct SyncWritePayload: Sendable {
    public var operationID: UUID
    public var note: NoteRecord
    public var html: String
    public var source: Data
    public var attachments: [(NoteAttachment, Data)]
}
public enum SyncReconciliation: Sendable { case applied(SyncRemoteSnapshot), notApplied, unknown }

/// Implementations must enforce the supplied base version atomically on the server.
/// A transport must not conform for production writes until that contract is verified.
public protocol SyncTransport: Sendable {
    func fetch(remoteID: String) async throws -> SyncRemoteSnapshot
    func write(_ payload: SyncWritePayload) async throws -> SyncRemoteSnapshot
    func reconcile(_ attempt: SyncAttempt) async throws -> SyncReconciliation
    func finish(operationID: UUID) async
}
public extension SyncTransport { func finish(operationID: UUID) async {} }

public enum SyncError: LocalizedError {
    case invalidBlocks, verificationFailed, uncertain
    case remoteChanged(SyncRemoteSnapshot)
    public var errorDescription: String? {
        switch self {
        case .invalidBlocks: return coreText("Check the references to preserved blocks.")
        case .verificationFailed: return coreText("The NAS save could not be confirmed yet. The source was kept while verification continues.")
        case .uncertain: return coreText("The previous upload could not be confirmed. Check the server before creating the note again.")
        case .remoteChanged: return coreText("The note changed on the NAS first. Review both versions.")
        }
    }
}

public actor SyncCoordinator {
    private let repository: NoteRepository
    private let attachments: AttachmentStore
    private let transport: any SyncTransport
    private let mathRenderer: (any MathImageRendering)?
    private let reportError: (@Sendable (UUID?, Error) async -> Void)?
    private var running = false
    public init(repository: NoteRepository, attachments: AttachmentStore, transport: any SyncTransport,
                mathRenderer: (any MathImageRendering)? = nil,
                reportError: (@Sendable (UUID?, Error) async -> Void)? = nil) {
        self.repository = repository; self.attachments = attachments; self.transport = transport
        self.reportError = reportError
        self.mathRenderer = mathRenderer
    }
    public func push(noteIDs: Set<UUID>? = nil, progress: (@Sendable (Int, Int) async -> Void)? = nil) async {
        guard !running else { return }
        running = true
        defer { running = false }
        do {
            let attempts = try await repository.syncAttempts().filter { noteIDs?.contains($0.note.id) ?? true }
            let queue = try await repository.pendingOperations().filter { noteIDs?.contains($0.noteID) ?? true }
            let now = Date()
            let ready = queue.filter {
                $0.state != .conflict && $0.state != .uncertain && ($0.state == .pending || $0.nextAttemptAt <= now)
            }
            let total = Set(attempts.map { $0.note.id }).union(ready.map(\.noteID)).count
            var processed = 0
            if total > 0 { await progress?(processed, total) }
            // Persisted attempts may have reached the server. Reconcile them before any retry.
            var restored: Set<UUID> = []
            for attempt in attempts {
                do {
                    switch try await transport.reconcile(attempt) {
                    case .applied(let snapshot):
                        try verify(snapshot, attempt: attempt)
                        try await repository.completeSync(attempt, snapshot: snapshot)
                        await transport.finish(operationID: attempt.operation.id)
                    case .notApplied:
                        try await repository.restoreRetryableAfterNotApplied(noteID: attempt.note.id)
                        restored.insert(attempt.note.id)
                        continue
                    case .unknown:
                        try await repository.fail(noteID: attempt.note.id, message: SyncError.uncertain.localizedDescription, uncertain: true)
                    }
                } catch SyncError.remoteChanged(let snapshot) {
                    do {
                        if try await repository.recordConflict(noteID: attempt.note.id, snapshot: snapshot) {
                            await transport.finish(operationID: attempt.operation.id)
                        }
                    } catch { /* Keep the attempt and transport journal intact. */ }
                } catch {
                    await reportError?(attempt.note.id, error)
                    try? await repository.fail(noteID: attempt.note.id, message: error.localizedDescription, uncertain: true)
                }
                processed += 1
                await progress?(processed, total)
            }
            let attempted = Set(attempts.map { $0.note.id })
            let readyIDs = Set(ready.map(\.noteID)).subtracting(attempted).union(restored)
            for operation in try await repository.pendingOperations() where readyIDs.contains(operation.noteID) {
                guard !Task.isCancelled else { return }
                guard operation.state != .conflict, operation.state != .uncertain else { continue }
                await process(operation)
                processed += 1
                await progress?(processed, total)
            }
        } catch {
            await reportError?(nil, error)
            // A repository failure cannot be reclassified as a successful sync.
            // Note-specific failures are persisted by process; the caller can retry the coordinator.
        }
    }

    private func process(_ operation: PendingOperation) async {
        var attempted = false
        do {
            guard var note = try await repository.note(id: operation.noteID), note.revision == operation.revision else { return }
            guard note.mode != .locked, note.mode == .original || MarkdownPipeline.validateBlocks(note.markdown, blocks: note.activeBlocks) else { throw SyncError.invalidBlocks }
            if note.mode == .markdown { note = try await preparingMathImages(in: note) }
            var verified: [(NoteAttachment, Data)] = []
            for attachment in note.attachments { verified.append((attachment, try await attachments.verifiedData(for: attachment))) }
            if let remoteID = note.remoteID {
                let current = try await transport.fetch(remoteID: remoteID)
                if current.version != operation.baseVersion {
                    try await repository.recordConflict(noteID: note.id, snapshot: current)
                    return
                }
            }
            let html = note.mode == .original ? note.originalHTML : try MathExport.html(markdown: note.markdown, blocks: note.activeBlocks, attachments: note.attachments)
            let source = SourceEnvelope(documentID: note.sourceDocumentID ?? note.id, markdown: note.markdown,
                                        blocks: note.activeBlocks, html: html, operationID: operation.id).encoded()
            let attempt = SyncAttempt(operation: operation, note: note, html: html, source: source)
            // A durable journal comes before the network side effect, including creates.
            try await repository.beginSync(attempt)
            attempted = true
            let response = try await transport.write(SyncWritePayload(operationID: operation.id, note: note, html: html, source: source, attachments: verified))
            let readback = try await transport.fetch(remoteID: response.remoteID)
            try verify(readback, attempt: attempt)
            try await repository.completeSync(attempt, snapshot: readback)
            await transport.finish(operationID: operation.id)
        } catch SyncError.remoteChanged(let snapshot) {
            do {
                if try await repository.recordConflict(noteID: operation.noteID, snapshot: snapshot) {
                    await transport.finish(operationID: operation.id)
                }
            } catch { /* Keep the attempt and transport journal intact. */ }
        } catch {
            await reportError?(operation.noteID, error)
            try? await repository.fail(noteID: operation.noteID, message: error.localizedDescription, uncertain: attempted)
        }
    }

    private func preparingMathImages(in input: NoteRecord) async throws -> NoteRecord {
        var note = input
        let formulas = MathExport.formulas(in: note.markdown, blocks: note.activeBlocks)
        let keys = Set(formulas.map(\.key))
        note.attachments.removeAll { $0.generatedMath.map { !keys.contains($0.key) } ?? false }
        var ready: Set<String> = []
        for asset in note.attachments {
            if let metadata = asset.generatedMath {
                guard metadata.isValid, ready.insert(metadata.key).inserted else { throw SyncError.verificationFailed }
                _ = try await attachments.verifiedData(for: asset)
            }
        }
        let missing = formulas.filter { !ready.contains($0.key) }
        if !missing.isEmpty {
            guard let mathRenderer else { throw RepositoryError(message: coreText("The math image renderer is unavailable. The source was preserved.")) }
            let rendered = try await mathRenderer.render(missing)
            guard rendered.count == missing.count, Set(rendered.map(\.key)) == Set(missing.map(\.key)) else { throw SyncError.verificationFailed }
            for image in rendered {
                let metadata = MathAttachmentMetadata(key: image.key, width: image.width, height: image.height)
                guard metadata.isValid, image.data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw SyncError.verificationFailed }
                var asset = try await attachments.importData(image.data, name: "synology-note-math-\(image.key).png")
                asset.generatedMath = metadata
                note.attachments.append(asset)
            }
        }
        return note
    }

    private func verify(_ snapshot: SyncRemoteSnapshot, attempt: SyncAttempt) throws {
        guard !snapshot.remoteID.isEmpty, !snapshot.version.isEmpty else { throw SyncError.verificationFailed }
        if let summary = snapshot.summary {
            guard summary.title == attempt.note.title, summary.notebookID == attempt.note.notebookID,
                  Set(summary.tags) == Set(attempt.note.tags), summary.isTrashed == attempt.note.isTrashed,
                  attempt.note.isTrashed || summary.isFavorite == attempt.note.isFavorite else { throw SyncError.verificationFailed }
        }
        if attempt.note.mode == .original {
            guard HTMLAttachmentComparison.matches(attempt.html, snapshot.html, expectedAssets: attempt.note.attachments, actualAssets: snapshot.attachments ?? []) else { throw SyncError.verificationFailed }
            return
        }
        guard !snapshot.remoteID.isEmpty, !snapshot.version.isEmpty,
              let source = snapshot.source,
              let envelope = try? SourceEnvelope.decode(source),
              envelope.documentID == (attempt.note.sourceDocumentID ?? attempt.note.id),
              envelope.operationID == attempt.operation.id,
              envelope.matches(html: snapshot.html),
              Data(envelope.markdown.utf8) == Data(attempt.note.markdown.utf8),
              envelope.blocks == attempt.note.activeBlocks else { throw SyncError.verificationFailed }
    }
}
