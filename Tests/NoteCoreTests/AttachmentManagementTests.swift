import Foundation
import Testing
@testable import NoteCore

@Suite struct AttachmentManagementTests {
    @Test func entityEncodedReferenceInPreservedBlockBlocksRemoval() throws {
        let asset = NoteAttachment(name: "image.png", filename: "asset", sha256: "hash", byteCount: 1, remoteID: "file-123")
        let block = PreservedBlock(id: "opaque-entity", html: "<img ref='file&#45;123'>", label: "원본")
        var note = NoteRecord(markdown: MarkdownPipeline.token(for: block))
        note.blocks = [block]; note.attachments = [asset]
        #expect(throws: RepositoryError.self) { try AttachmentManagement.removing(asset, from: note) }
    }

    @Test func removingUnreferencedFileDeletesNASAssetButKeepsLocalBytesAndHistory() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        var note = NoteRecord(title: "파일 관리", notebookID: "book", markdown: "보존할 본문")
        let data = Data([1, 2, 3, 4])
        let asset = try await f.assets.importData(data, name: "keep-history.bin")
        note.attachments = [asset]
        note = try await f.repo.save(note)
        await f.coordinator.push()
        note = try #require(try await f.repo.note(id: note.id))
        let remoteID = try #require(note.remoteID)
        let currentAsset = try #require(note.attachments.first { $0.name == "keep-history.bin" })
        let removed = try #require(currentAsset.remoteID)
        note.attachments.removeAll { $0.id == currentAsset.id }
        _ = try await f.repo.save(note)
        await f.coordinator.push()
        let remote = try await f.client.fetch(noteID: remoteID)
        #expect(!remote.attachments.contains { $0.id == removed })
        #expect(try await f.repo.note(id: note.id)?.syncState == .synced)
        #expect(try await f.assets.verifiedData(for: asset) == data)
        #expect(try await f.repo.revisions(noteID: note.id).contains { $0.note.attachments.contains { $0.id == asset.id } })
    }
}

extension AttachmentManagementTests {
    @Test func lostDeletionResponseReconcilesWithoutAnotherWrite() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        let asset = try await f.assets.importData(Data([5, 4]), name: "remove.bin")
        var note = NoteRecord(title: "삭제 응답 유실", notebookID: "book", markdown: "[파일](\(asset.reference))")
        note.attachments = [asset]; note = try await f.repo.save(note); await f.coordinator.push()
        note = try #require(try await f.repo.note(id: note.id))
        let attachment = try #require(note.attachments.first { $0.id == asset.id })
        let bridge = RemovalBridge(server: f.server, fileID: try #require(attachment.remoteID), loseAfterRemoval: true)
        defer { bridge.close() }
        let client = NoteStationClient(baseURL: URL(string: "https://\(bridge.host)")!, session: bridge.session, allowsValidatedWrites: true)
        try await client.connect(username: "test", password: "test")
        note.markdown = "남겨둘 문단"; note.attachments.removeAll { $0.id == attachment.id }
        _ = try await f.repo.save(note)
        let coordinator = SyncCoordinator(repository: f.repo, attachments: f.assets,
            transport: try NoteStationSyncTransport(client: client, repository: f.repo, assets: f.assets, directory: f.journal))
        await coordinator.push()
        #expect(try await f.repo.syncAttempts().count == 1)
        let writes = f.server.counts().sets
        await coordinator.push()
        #expect(try await f.repo.note(id: note.id)?.syncState == .synced)
        #expect(try await f.repo.syncAttempts().isEmpty)
        #expect(f.server.counts().sets == writes)
        #expect(try await f.assets.verifiedData(for: attachment) == Data([5, 4]))
    }

    @Test func restoringDuringRemovalUploadPreservesUserIntent() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        var note = NoteRecord(title: "실행 취소", notebookID: "book", markdown: "[파일](placeholder)")
        let original = try await f.assets.importData(Data([9, 8]), name: "restore.bin")
        note.attachments = [original]; note.markdown = "[파일](\(original.reference))"
        note = try await f.repo.save(note); await f.coordinator.push()
        note = try #require(try await f.repo.note(id: note.id))
        let attachment = try #require(note.attachments.first { $0.id == original.id })
        let pause = RemovalPause()
        let bridge = RemovalBridge(server: f.server, fileID: try #require(attachment.remoteID), pause: pause)
        defer { bridge.close() }
        let client = NoteStationClient(baseURL: URL(string: "https://\(bridge.host)")!, session: bridge.session, allowsValidatedWrites: true)
        try await client.connect(username: "test", password: "test")
        note.markdown = "본문 보존"; note.attachments.removeAll { $0.id == attachment.id }
        _ = try await f.repo.save(note)
        let coordinator = SyncCoordinator(repository: f.repo, attachments: f.assets,
            transport: try NoteStationSyncTransport(client: client, repository: f.repo, assets: f.assets, directory: f.journal))
        let push = Task { await coordinator.push() }
        await pause.waitUntilStarted()
        var restored = try #require(try await f.repo.note(id: note.id))
        restored.markdown = "[파일](\(attachment.reference))"; restored.attachments.append(attachment)
        _ = try await f.repo.save(restored)
        await pause.resume(); await push.value
        let saved = try #require(try await f.repo.note(id: note.id))
        #expect(saved.attachments.contains { $0.id == attachment.id })
        #expect(saved.markdown == "[파일](\(attachment.reference))")
        #expect(try await f.assets.verifiedData(for: attachment) == Data([9, 8]))
    }
}

private actor RemovalPause {
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation; started = true
            startedContinuation?.resume(); startedContinuation = nil
        }
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { startedContinuation = $0 } } }
    func resume() { resumeContinuation?.resume(); resumeContinuation = nil }
}
private final class RemovalBridge: @unchecked Sendable {
    let host = "removal-\(UUID().uuidString.lowercased()).invalid"
    let session: URLSession, server: ProductionNAS, fileID: String, pause: RemovalPause?
    let loseAfterRemoval: Bool
    init(server: ProductionNAS, fileID: String, pause: RemovalPause? = nil, loseAfterRemoval: Bool = false) {
        self.server = server; self.fileID = fileID; self.pause = pause; self.loseAfterRemoval = loseAfterRemoval
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RemovalProtocol.self]
        session = URLSession(configuration: config); RemovalProtocol.register(self)
    }
    func close() { RemovalProtocol.unregister(host); session.invalidateAndCancel() }
}
private final class RemovalProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock(); private static var bridges: [String: RemovalBridge] = [:]
    static func register(_ bridge: RemovalBridge) { lock.lock(); defer { lock.unlock() }; bridges[bridge.host] = bridge }
    static func unregister(_ host: String) { lock.lock(); defer { lock.unlock() }; bridges.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let bridge = Self.bridges[request.url?.host ?? ""]; Self.lock.unlock()
        guard let bridge, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
            while true { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; bytes.append(buffer,count:n) }
        }
        var captured = request; captured.httpBody = bytes
        let (body, lost) = bridge.server.reply(captured)
        let text = String(decoding: bytes, as: UTF8.self).removingPercentEncoding ?? ""
        let removesUserFile = text.contains("\"action\":\"delete\"") && text.contains("\"file_id\":\"\(bridge.fileID)\"")
        Task {
            if removesUserFile, let pause = bridge.pause { await pause.wait() }
            if lost || (removesUserFile && bridge.loseAfterRemoval) { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
