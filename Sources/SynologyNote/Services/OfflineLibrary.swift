import Foundation
import NoteCore

extension LibraryStore {
    func setOfflineStorage(_ enabled: Bool) {
        profile.keepOffline = enabled; profile.persist(to: preferences)
        if enabled { startOfflineDownload() }
        else { cancelOfflineDownload(); offlineStatus = "오프라인 보관 일시 중지" }
    }

    func cancelOfflineDownload() {
        offlineRunID = UUID(); offlineTask?.cancel(); offlineTask = nil; isCachingOffline = false
    }

    func startOfflineDownload() {
        guard profile.keepOffline, isConnected, !isCachingOffline, let client else { return }
        let run = UUID(), connection = connectionGeneration, account = accountGeneration
        let repo = repository, assets = attachments
        offlineRunID = run; isCachingOffline = true
        offlineTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.offlineRunID == run { self.isCachingOffline = false; self.offlineTask = nil } }
            do {
                let candidates = try await repo.offlineCandidates()
                guard self.offlineRunID == run else { return }
                self.offlineTotal = candidates.count; self.offlineCompleted = 0; self.offlineFailures = [:]
                for candidate in candidates {
                    guard !Task.isCancelled, self.offlineRunID == run, connection == self.connectionGeneration,
                          account == self.accountGeneration, self.isConnected else { return }
                    // Never block editing/uploads behind an entire library download.
                    if self.isPushing { self.offlineStatus = "NAS 전송 후 오프라인 보관 재개"; return }
                    self.offlineStatus = "본문·첨부 보관 중 \(self.offlineCompleted)/\(self.offlineTotal)"
                    do {
                        guard let remoteID = candidate.remoteID else { continue }
                        if try await repo.pendingOperations().contains(where: { $0.noteID == candidate.id }) { continue }
                        if let session = self.sessions[candidate.id], session.editGeneration != session.savedGeneration { continue }
                        let incoming = try await Self.downloadedRecord(noteID: remoteID, client: client, repo: repo, assets: assets)
                        guard !Task.isCancelled, self.offlineRunID == run, connection == self.connectionGeneration,
                              account == self.accountGeneration else { return }
                        let hasPending = try await repo.pendingOperations().contains(where: { $0.noteID == candidate.id })
                        if self.isPushing || hasPending { continue }
                        if let session = self.sessions[candidate.id], session.editGeneration != session.savedGeneration { continue }
                        let merged = try await repo.mergeRemote(incoming)
                        if let session = self.sessions[candidate.id], session.editGeneration == session.savedGeneration {
                            session.note = merged
                        }
                        self.offlineCompleted += 1
                        if self.offlineCompleted.isMultiple(of: 10) { try await self.reload() }
                    } catch {
                        guard self.offlineRunID == run, !Task.isCancelled else { return }
                        self.offlineFailures[candidate.id] = error.localizedDescription
                        if Self.isRecoverableConnectionError(error) {
                            self.requestConnectionRecovery(after: error)
                            return
                        }
                    }
                }
                guard self.offlineRunID == run else { return }
                try await self.reload()
                let remaining = try await repo.offlineCandidates().count
                self.offlineStatus = remaining == 0 ? "전체 노트·첨부 오프라인 보관 완료" : "\(remaining)개 보관 대기 · \(self.offlineFailures.count)개 확인 필요"
            } catch {
                if self.offlineRunID == run { self.offlineStatus = "오프라인 보관 확인 필요"; self.connectionError = error.localizedDescription }
            }
        }
    }

    static func downloadedRecord(noteID: String, client: NoteStationClient, repo: NoteRepository, assets: AttachmentStore) async throws -> NoteRecord {
        let remote = try await client.fetch(noteID: noteID)
        var incoming = Self.record(from: remote.summary)
        incoming.originalHTML = remote.html; incoming.hasRemoteContent = true; incoming.listedVersion = remote.summary.version
        let existing = try await repo.note(remoteID: noteID)
        var sources: [SourceEnvelope] = []
        for file in remote.attachments {
            try Task.checkCancellation()
            let bytes = try await client.download(fileID: file.id, noteID: noteID)
            if file.name.hasSuffix(".md"), let source = try? SourceEnvelope.decode(bytes), source.matches(html: remote.html) { sources.append(source) }
            var attachment: NoteAttachment
            if let cached = existing?.attachments.first(where: { $0.remoteID == file.id }),
               let data = try? await assets.verifiedData(for: cached), data == bytes {
                attachment = cached; attachment.name = file.name
            } else { attachment = try await assets.importData(bytes, name: file.name) }
            attachment.remoteID = file.id; attachment.remoteReference = file.reference
            if let id = file.reference.flatMap(UUID.init(uuidString:)) { attachment.id = id }
            incoming.attachments.append(attachment)
        }
        if sources.count == 1, let source = sources.first, let restored = try? source.restoredAttachments(from: incoming.attachments) {
            incoming.attachments = restored; incoming.sourceDocumentID = source.documentID
            incoming.markdown = source.markdown; incoming.blocks = source.blocks; incoming.mode = .markdown
        }
        return incoming
    }
}
