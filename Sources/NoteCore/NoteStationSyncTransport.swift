import Foundation
import SwiftSoup
import UniformTypeIdentifiers

/// Removal never rewrites user content. Referenced files must first be removed
/// deliberately in the editor; inactive block registry entries remain for undo.
public enum AttachmentManagement {
    public static func removing(_ attachment: NoteAttachment, from note: NoteRecord) throws -> NoteRecord {
        guard note.mode != .locked, note.hasRemoteContent else {
            throw RepositoryError(message: coreText("Download the note body before removing an attachment."))
        }
        guard let attachment = note.attachments.first(where: { $0.id == attachment.id }) else { throw AttachmentError.missing }
        if note.mode == .markdown, let math = attachment.generatedMath,
           MathExport.formulas(in: note.markdown).contains(where: { $0.key == math.key }) {
            throw RepositoryError(message: coreText("The body uses this math image. Remove the equation first."))
        }
        let rendered = note.mode == .original ? note.originalHTML : MarkdownPipeline.render(note.markdown, blocks: note.activeBlocks)
        let identities = [attachment.id.uuidString, attachment.remoteID, attachment.remoteReference].compactMap { $0 }
        let markdownReferences = note.mode == .markdown && identities.contains(where: { note.markdown.localizedCaseInsensitiveContains($0) })
        let renderedReferences = try referencesHTML(rendered, identities: identities, name: attachment.name)
        let blockReferences = try note.activeBlocks.contains { try referencesHTML($0.html, identities: identities, name: attachment.name) }
        if markdownReferences || renderedReferences || blockReferences {
            throw RepositoryError(message: coreText("The body or a preserved block uses this attachment. Remove the reference first."))
        }
        var result = note
        result.attachments.removeAll { $0.id == attachment.id }
        return result
    }

    static func referencesHTML(_ html: String, identities: [String], name: String) throws -> Bool {
        let identities = identities.filter { !$0.isEmpty }
        // Conservative fallback covers CSS URLs and unsupported rich blocks.
        let decoded = html.removingPercentEncoding ?? html
        if identities.contains(where: { decoded.localizedCaseInsensitiveContains($0) }) { return true }
        let dom = try SwiftSoup.parseBodyFragment(html)
        for element in try dom.select("[ref], [content_id], [src], [href], [data], [poster], [style], [srcset]").array() {
            for attr in ["ref", "content_id", "src", "href", "data", "poster", "style", "srcset"] {
                let decodedValue = try element.attr(attr)
                let value = decodedValue.removingPercentEncoding ?? decodedValue
                if identities.contains(where: { value.localizedCaseInsensitiveContains($0) }) { return true }
                if ["ref", "content_id"].contains(attr), !name.isEmpty, value == name { return true }
                if let url = URLComponents(string: value), (url.queryItems ?? []).contains(where: {
                    ["ref", "content_id"].contains($0.name) && $0.value == name && !name.isEmpty
                }) { return true }
            }
        }
        return false
    }
}

/// Each physical write is preceded by an atomic local journal update. A lost
/// create response never falls back to another create. Ambiguous intermediate
/// results stop for reconciliation rather than adopting an unproven version.
public actor NoteStationSyncTransport: SyncTransport {
    private let client: NoteStationClient
    private let repository: NoteRepository
    private let assets: AttachmentStore
    private let directory: URL
    private var cache: [String: SyncRemoteSnapshot] = [:]

    private struct Journal: Codable {
        enum Phase: String, Codable { case prepared, staging, staged, body, bodySaved, publishing, published }
        var phase: Phase = .prepared
        var operationID: UUID
        var documentID: UUID
        var remoteID: String?
        var baseVersion: String?
        var initialHTML: String
        var stageName: String
        var stageSource: Data
        var stageVersion: String?
        var bodyVersion: String?
        var preparedHTML: String?
        var finalSource: Data?
        var finalVersion: String?
        var bindings: [String: String] = [:]
        var removed: [String] = []
        var removedUserAttachments: [String]?
    }

    public init(client: NoteStationClient, repository: NoteRepository, assets: AttachmentStore, directory: URL) throws {
        self.client = client; self.repository = repository; self.assets = assets; self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func fetch(remoteID: String) async throws -> SyncRemoteSnapshot {
        let remote = try await read(remoteID)
        if let cached = cache[remoteID], cached.version == remote.summary.version {
            var updated = cached; updated.summary = remote.summary
            return updated
        }
        return try await snapshot(remote)
    }

    public func write(_ payload: SyncWritePayload) async throws -> SyncRemoteSnapshot {
        guard client.capabilities.supportsWrites else { throw NoteStationError.writeContractUnvalidated }
        guard let attempt = try await repository.syncAttempts().first(where: { $0.operation.id == payload.operationID }) else { throw SyncError.verificationFailed }
        var journal: Journal
        if let stored = try load(payload.operationID) { journal = stored }
        else {
            let note = attempt.note
            guard note.notebookID != "local", !note.notebookID.hasPrefix("local-") else { throw NoteStationError.invalidArgument("NAS notebook") }
            let initial: String
            var removed: [String] = []
            if let id = note.remoteID {
                let remote = try await read(id)
                guard remote.summary.version == attempt.operation.baseVersion else { throw SyncError.remoteChanged(try await snapshot(remote)) }
                initial = remote.html
                if note.mode == .markdown || note.mode == .original {
                    guard note.hasRemoteContent else { throw SyncError.verificationFailed }
                    let desiredIDs = Set(note.attachments.compactMap(\.remoteID))
                    let desiredRefs = Set(note.attachments.flatMap { [$0.id.uuidString, $0.remoteReference].compactMap { $0 } })
                    let desiredHTML = note.mode == .original ? note.originalHTML : try MathExport.html(markdown: note.markdown, blocks: note.activeBlocks, attachments: note.attachments)
                    for file in remote.attachments where !desiredIDs.contains(file.id) && !(file.reference.map(desiredRefs.contains) ?? false) {
                        if file.name.hasSuffix(".md"), let source = try? SourceEnvelope.decode(try await client.download(fileID: file.id, noteID: id)),
                           source.documentID == (note.sourceDocumentID ?? note.id) { continue }
                        guard try !AttachmentManagement.referencesHTML(desiredHTML, identities: [file.id, file.reference].compactMap { $0 }, name: file.name) else {
                            throw RepositoryError(message: coreText("A NAS attachment referenced in the body cannot be removed."))
                        }
                        removed.append(file.id)
                    }
                }
                if note.mode == .original, let base = note.baseHTML, initial != base { throw SyncError.remoteChanged(try await snapshot(remote)) }
            } else {
                guard note.mode == .markdown else { throw SyncError.invalidBlocks }
                initial = "<p>문서를 전송하고 있습니다.</p>"
            }
            let documentID = note.sourceDocumentID ?? note.id
            let stage = SourceEnvelope(documentID: documentID, markdown: note.markdown, blocks: note.activeBlocks,
                                       html: initial, operationID: payload.operationID, isStaging: true).encoded()
            journal = Journal(operationID: payload.operationID, documentID: documentID, remoteID: note.remoteID,
                              baseVersion: attempt.operation.baseVersion, initialHTML: initial,
                              stageName: "synology-note-upload-\(documentID)-\(payload.operationID).md", stageSource: stage, removed: removed, removedUserAttachments: removed)
            try save(journal)
        }
        return try await advance(&journal, attempt: attempt, verified: payload.attachments)
    }

    public func reconcile(_ attempt: SyncAttempt) async throws -> SyncReconciliation {
        guard var journal = try load(attempt.operation.id) else { return .notApplied }
        if journal.phase == .prepared { return .notApplied }
        let remote: RemoteNote
        if let id = journal.remoteID {
            remote = try await read(id)
        } else {
            // The exact staging marker identifies the create even if its receipt was lost.
            guard let created = try await findStagedCreate(journal, note: attempt.note) else { return .unknown }
            remote = created
            journal.remoteID = created.summary.id
            try save(journal)
        }
        try await repository.bindRemoteID(noteID: attempt.note.id, remoteID: remote.summary.id)
        let verified = try await localAssets(attempt.note)
        if attempt.note.mode == .markdown, try await publishedSource(remote, attempt: attempt) != nil {
            return .applied(try await finishConfirmed(&journal, attempt: attempt, verified: verified))
        }
        if journal.phase == .staging {
            if let baseVersion = journal.baseVersion {
                guard remote.summary.version == baseVersion else { return .unknown }
                journal.phase = .prepared
                try save(journal)
                return .notApplied
            }
            guard try await isUntouchedStagedCreate(remote, journal: journal, note: attempt.note,
                                                    files: userAssets(verified, documentID: journal.documentID)) else {
                return .unknown
            }
            // Every subsequent write uses the observed version as its CAS condition.
            journal.stageVersion = remote.summary.version
            journal.phase = .staged
            try save(journal)
        }
        if journal.phase == .body, journal.bodyVersion == nil, remote.summary.version != journal.stageVersion {
            // Content may already have reached NAS, but no acknowledged base for
            // the source publication exists. Preserve the local attempt.
            return .unknown
        }
        return .applied(try await advance(&journal, attempt: attempt, verified: verified))
    }

    private func findStagedCreate(_ journal: Journal, note: NoteRecord) async throws -> RemoteNote? {
        var match: RemoteNote?
        for candidate in try await client.notes() where candidate.title == note.title && candidate.notebookID == note.notebookID {
            let remote = try await read(candidate.id)
            guard try await stagingMarker(in: remote, journal: journal) != nil else { continue }
            guard match == nil else { return nil }
            match = remote
        }
        return match
    }

    private func stagingMarker(in remote: RemoteNote, journal: Journal) async throws -> RemoteAttachment? {
        let markers = remote.attachments.filter { $0.name == journal.stageName }
        guard markers.count == 1, let marker = markers.first,
              try await client.download(fileID: marker.id, noteID: remote.summary.id) == journal.stageSource else { return nil }
        return marker
    }

    private func isUntouchedStagedCreate(_ remote: RemoteNote, journal: Journal, note: NoteRecord,
                                         files: [(NoteAttachment, Data)]) async throws -> Bool {
        let summary = remote.summary
        guard summary.title == note.title, summary.notebookID == note.notebookID,
              summary.tags.isEmpty, !summary.isFavorite, !summary.isTrashed, !summary.isLocked,
              remote.html == journal.initialHTML, remote.attachments.count == files.count + 1,
              let marker = try await stagingMarker(in: remote, journal: journal) else { return false }
        var attached = remote
        attached.attachments.removeAll { $0.id == marker.id }
        let bindings = try await bindAndVerify(files, in: attached)
        return Set(bindings.values) == Set(attached.attachments.map(\.id))
    }

    public func finish(operationID: UUID) async {
        try? FileManager.default.removeItem(at: journalURL(operationID))
    }

    private func advance(_ journal: inout Journal, attempt: SyncAttempt, verified: [(NoteAttachment, Data)]) async throws -> SyncRemoteSnapshot {
        let note = attempt.note
        let files = userAssets(verified, documentID: journal.documentID)
        if journal.phase == .prepared {
                let current = try await journal.remoteID.asyncMap { try await read($0) }
                if let current, current.summary.version != journal.baseVersion { throw SyncError.remoteChanged(try await snapshot(current)) }
                var uploads = files.filter { asset, _ in !((asset.remoteID).map { id in current?.attachments.contains(where: { $0.id == id }) == true } ?? false) }
                    .map { asset, data in NoteStationUpload(name: asset.name, mimeType: mime(asset.name), bytes: data, reference: asset.id.uuidString) }
                if note.mode == .markdown { uploads.append(NoteStationUpload(name: journal.stageName, mimeType: "text/markdown", bytes: journal.stageSource, reference: nil)) }
                if uploads.isEmpty {
                    journal.stageVersion = journal.baseVersion; journal.phase = .staged; try save(journal)
                } else {
                journal.phase = .staging; try save(journal)
                do {
                    let receipt = try await client.applyWrite(NoteStationWrite(objectID: journal.remoteID, baseVersion: journal.baseVersion,
                        title: journal.remoteID == nil ? note.title : nil, notebookID: journal.remoteID == nil ? note.notebookID : nil,
                        html: journal.remoteID == nil ? journal.initialHTML : nil), uploads: uploads)
                    journal.remoteID = receipt.objectID; journal.stageVersion = receipt.version; journal.phase = .staged
                    try save(journal)
                    try await repository.bindRemoteID(noteID: note.id, remoteID: receipt.objectID)
                } catch NoteStationError.versionConflict {
                    throw SyncError.remoteChanged(try await fetch(remoteID: journal.remoteID!))
                } catch {
                    if definitelyRejected(error) { journal.phase = .prepared; try save(journal) }
                    throw error
                }
            }
        }
        guard let id = journal.remoteID else { throw SyncError.uncertain }
        if journal.phase == .staged {
            let current = try await read(id)
            guard current.summary.version == journal.stageVersion else { throw SyncError.remoteChanged(try await snapshot(current)) }
            journal.bindings = try await bindAndVerify(files, in: current)
            journal.preparedHTML = try await html(note, remoteID: id, bindings: journal.bindings)
            journal.phase = .body; try save(journal)
        }
        if journal.phase == .body {
            let current = try await read(id)
            guard current.summary.version == journal.stageVersion else { throw SyncError.remoteChanged(try await snapshot(current)) }
            do {
                let receipt = try await client.applyWrite(NoteStationWrite(objectID: id, baseVersion: journal.stageVersion,
                    title: note.title, notebookID: note.notebookID,
                    html: note.mode == .original && journal.preparedHTML == journal.initialHTML ? nil : journal.preparedHTML,
                    tags: note.tags, recycle: note.isTrashed), deleting: note.mode == .original ? journal.removed : [])
                journal.bodyVersion = receipt.version; journal.phase = .bodySaved; try save(journal)
            } catch NoteStationError.versionConflict { throw SyncError.remoteChanged(try await fetch(remoteID: id)) }
        }
        if journal.phase == .bodySaved {
            let current = try await read(id)
            guard current.summary.version == journal.bodyVersion else { throw SyncError.remoteChanged(try await snapshot(current)) }
            guard let expected = journal.preparedHTML,
                  ServerHTMLComparison.matches(expected, current.html, allowsCodeNormalization: note.mode == .markdown && note.activeBlocks.isEmpty),
                  metadataMatches(current.summary, note: note) else { throw SyncError.verificationFailed }
            if note.mode == .original {
                journal.finalVersion = journal.bodyVersion; journal.phase = .published; try save(journal)
            } else {
                journal.finalSource = SourceEnvelope(documentID: journal.documentID, markdown: note.markdown, blocks: note.activeBlocks,
                    html: current.html, operationID: attempt.operation.id, attachmentBindings: journal.bindings,
                    mathAttachments: Dictionary(uniqueKeysWithValues: note.attachments.compactMap { asset in asset.generatedMath.map { (asset.id.uuidString, $0) } })).encoded()
                var removed: [String] = journal.removed
                for file in current.attachments where file.name.hasSuffix(".md") {
                    let bytes = try await client.download(fileID: file.id, noteID: id)
                    if let source = try? SourceEnvelope.decode(bytes), source.documentID == journal.documentID,
                       !source.isStaging || source.operationID == attempt.operation.id { removed.append(file.id) }
                }
                journal.removed = Array(Set(removed)).sorted(); journal.phase = .publishing; try save(journal)
            }
        }
        if journal.phase == .publishing {
            let current = try await read(id)
            guard current.summary.version == journal.bodyVersion else {
                if try await publishedSource(current, attempt: attempt) != nil { return try await finishConfirmed(&journal, attempt: attempt, verified: verified) }
                throw SyncError.remoteChanged(try await snapshot(current))
            }
            for file in current.attachments where journal.removed.contains(file.id) {
                guard try !AttachmentManagement.referencesHTML(current.html, identities: [file.id, file.reference].compactMap { $0 }, name: file.name) else {
                    throw SyncError.verificationFailed
                }
            }
            do {
                let receipt = try await client.applyWrite(NoteStationWrite(objectID: id, baseVersion: journal.bodyVersion),
                    uploads: [NoteStationUpload(name: "synology-note-source-\(journal.documentID).md", mimeType: "text/markdown",
                                               bytes: journal.finalSource!, reference: nil)], deleting: journal.removed)
                journal.finalVersion = receipt.version; journal.phase = .published; try save(journal)
            } catch NoteStationError.versionConflict {
                let current = try await read(id)
                if try await publishedSource(current, attempt: attempt) == nil { throw SyncError.remoteChanged(try await snapshot(current)) }
            }
        }
        return try await finishConfirmed(&journal, attempt: attempt, verified: verified)
    }

    private func finishConfirmed(_ journal: inout Journal, attempt: SyncAttempt, verified: [(NoteAttachment, Data)]) async throws -> SyncRemoteSnapshot {
        guard let id = journal.remoteID else { throw SyncError.uncertain }
        var current = try await read(id)
        guard metadataMatches(current.summary, note: attempt.note) else { throw SyncError.remoteChanged(try await snapshot(current)) }
        if attempt.note.mode == .markdown {
            guard try await publishedSource(current, attempt: attempt) != nil else { throw SyncError.verificationFailed }
            _ = try await bindAndVerify(userAssets(verified, documentID: journal.documentID), in: current, bindings: journal.bindings)
        } else { guard current.html == journal.preparedHTML else { throw SyncError.remoteChanged(try await snapshot(current)) } }
        if !attempt.note.isTrashed, current.summary.isFavorite != attempt.note.isFavorite {
            try await client.setFavorite(noteID: id, favorite: attempt.note.isFavorite)
            current = try await read(id)
        }
        guard metadataMatches(current.summary, note: attempt.note), attempt.note.isTrashed || current.summary.isFavorite == attempt.note.isFavorite else { throw SyncError.verificationFailed }
        if attempt.note.mode == .markdown, try await publishedSource(current, attempt: attempt) == nil { throw SyncError.remoteChanged(try await snapshot(current)) }
        guard !current.attachments.contains(where: { journal.removed.contains($0.id) }) else { throw SyncError.verificationFailed }
        var result = try await snapshot(current)
        if attempt.note.mode == .markdown, result.source != journal.finalSource {
            cache.removeValue(forKey: id)
            throw SyncError.verificationFailed
        }
        // A newer local revision may have restored a removed user asset with
        // undo. Only protocol-source pruning is forced onto that newer revision;
        // user assets stay pending and will upload again if their NAS ID is gone.
        result.removedAttachmentIDs = journal.removed.filter { !(journal.removedUserAttachments ?? []).contains($0) }
        cache[id] = result
        return result
    }

    private func publishedSource(_ remote: RemoteNote, attempt: SyncAttempt) async throws -> SourceEnvelope? {
        for file in remote.attachments where file.name.hasSuffix(".md") {
            let bytes = try await client.download(fileID: file.id, noteID: remote.summary.id)
            if let source = try? SourceEnvelope.decode(bytes), source.documentID == (attempt.note.sourceDocumentID ?? attempt.note.id),
               source.operationID == attempt.operation.id, source.matches(html: remote.html),
               Data(source.markdown.utf8) == Data(attempt.note.markdown.utf8), source.blocks == attempt.note.activeBlocks { return source }
        }
        return nil
    }

    private func snapshot(_ remote: RemoteNote) async throws -> SyncRemoteSnapshot {
        var imported: [NoteAttachment] = [], sourceBytes: Data?, candidates: [SourceEnvelope] = []
        for file in remote.attachments {
            let bytes = try await client.download(fileID: file.id, noteID: remote.summary.id)
            if file.name.hasSuffix(".md"), let source = try? SourceEnvelope.decode(bytes), source.matches(html: remote.html) {
                candidates.append(source); sourceBytes = bytes
            }
            var asset = try await assets.importData(bytes, name: file.name)
            asset.remoteID = file.id; asset.remoteReference = file.reference
            if let id = file.reference.flatMap(UUID.init(uuidString:)) { asset.id = id }
            imported.append(asset)
        }
        guard candidates.count <= 1 else { throw SyncError.verificationFailed }
        if let source = candidates.first { imported = try source.restoredAttachments(from: imported) }
        let result = SyncRemoteSnapshot(remoteID: remote.summary.id, version: remote.summary.version, html: remote.html,
                                        source: sourceBytes, summary: remote.summary, attachments: imported)
        cache[remote.summary.id] = result
        return result
    }

    private func read(_ id: String) async throws -> RemoteNote {
        var result = try await client.fetch(noteID: id)
        result.summary.isFavorite = try await client.favoriteStatus(noteID: id)
        return result
    }
    private func metadataMatches(_ summary: RemoteNoteSummary, note: NoteRecord) -> Bool {
        summary.title == note.title && summary.notebookID == note.notebookID && Set(summary.tags) == Set(note.tags) && summary.isTrashed == note.isTrashed
    }
    private func localAssets(_ note: NoteRecord) async throws -> [(NoteAttachment, Data)] {
        var values: [(NoteAttachment, Data)] = []
        for asset in note.attachments { values.append((asset, try await assets.verifiedData(for: asset))) }
        return values
    }
    private func userAssets(_ values: [(NoteAttachment, Data)], documentID: UUID) -> [(NoteAttachment, Data)] {
        values.filter { _, bytes in (try? SourceEnvelope.decode(bytes))?.documentID != documentID }
    }
    private func bindAndVerify(_ values: [(NoteAttachment, Data)], in remote: RemoteNote, bindings: [String: String] = [:]) async throws -> [String: String] {
        var result: [String: String] = [:]
        for (asset, expected) in values {
            let matches = remote.attachments.filter { file in
                if let id = bindings[asset.id.uuidString] { return file.id == id }
                return file.id == asset.remoteID || file.reference.flatMap(UUID.init(uuidString:)) == asset.id
            }
            guard matches.count == 1, let file = matches.first else { throw RepositoryError(message: coreText("Could not identify a single matching NAS attachment.")) }
            guard try await client.download(fileID: file.id, noteID: remote.summary.id) == expected else { throw RepositoryError(message: coreText("The NAS attachment bytes differ from the local copy.")) }
            result[asset.id.uuidString] = file.id
        }
        return result
    }
    private func html(_ note: NoteRecord, remoteID: String, bindings: [String: String]) async throws -> String {
        if note.mode == .original, !note.originalHTML.lowercased().contains("attachment://") { return note.originalHTML }
        let rendered = note.mode == .original ? note.originalHTML : try MathExport.html(markdown: note.markdown, blocks: note.activeBlocks, attachments: note.attachments)
        var replacements: [(Range<Int>, String)] = []
        for slice in HTMLSourcePatcher.attachmentTags(in: rendered) {
            let dom = try SwiftSoup.parseBodyFragment(slice.html)
            guard let element = try dom.select(slice.name).first() else { throw SyncError.verificationFailed }
            let attr = slice.name == "img" ? "src" : "href"
            let value = try element.attr(attr)
            guard value.lowercased().hasPrefix("attachment:") else { continue }
            guard let id = URL(string: value)?.host.flatMap(UUID.init(uuidString:)), let fileID = bindings[id.uuidString] else { throw AttachmentError.missing }
            let replacement = Element(try Tag.valueOf(slice.name), "")
            for attribute in element.getAttributes()?.asList() ?? [] { try replacement.attr(attribute.getKey(), attribute.getValue()) }
            let scratch = try SwiftSoup.parseBodyFragment("")
            scratch.outputSettings().prettyPrint(pretty: false)
            try scratch.body()?.appendChild(replacement)
            try replacement.attr("ref", id.uuidString)
            if attr == "src" { try replacement.removeAttr("src") }
            else { try replacement.attr("href", await client.attachmentDownloadURL(fileID: fileID, noteID: remoteID)) }
            var tag = try replacement.outerHtml()
            if slice.name == "a", tag.hasSuffix("</a>") { tag = String(tag.dropLast(4)) }
            replacements.append((slice.range, tag))
        }
        return try HTMLSourcePatcher.replacing(in: rendered, replacements: replacements)
    }
    private func mime(_ name: String) -> String { UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream" }
    private func journalURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func save(_ journal: Journal) throws { try JSONEncoder().encode(journal).write(to: journalURL(journal.operationID), options: .atomic) }
    private func load(_ id: UUID) throws -> Journal? {
        let url = journalURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
    }
    private func definitelyRejected(_ error: Error) -> Bool {
        guard let error = error as? NoteStationError else { return false }
        switch error {
        case .permissionDenied, .sessionExpired, .unsupportedAPI, .notConnected, .writeContractUnvalidated: return true
        case .api(let code): return [101, 102, 103, 104, 114].contains(code)
        default: return false
        }
    }
}

private extension Optional {
    func asyncMap<T>(_ body: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await body(value)
    }
}
