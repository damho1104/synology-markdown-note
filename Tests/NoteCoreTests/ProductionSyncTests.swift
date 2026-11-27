import Foundation
import Testing
import SwiftSoup
@testable import NoteCore
@testable import SynologyNote

@Suite struct ProductionSyncTests {
    @Test func mermaidCodeNormalizationKeepsExactMarkdownAndDoesNotCreateConflict() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        f.server.normalizeCodeBlocksOnWrite()
        let markdown = "```mermaid\nflowchart LR\n    A[Markdown] --> B[Preview]\n```\n"
        let original = try await f.repo.save(NoteRecord(title: "Mermaid", notebookID: "book", markdown: markdown))
        await f.coordinator.push()
        let note = try #require(try await f.repo.note(id: original.id))
        #expect(note.syncState == .synced && note.conflictHTML == nil)
        #expect(note.markdown == markdown)
        let remote = try await f.client.fetch(noteID: try #require(note.remoteID))
        #expect(!remote.html.contains("language-mermaid"))
        #expect(try await f.repo.syncAttempts().isEmpty)
        var edited = note
        edited.markdown += "\n추가 설명\n"
        edited = try await f.repo.save(edited)
        await f.coordinator.push()
        #expect(try await f.repo.note(id: edited.id)?.syncState == .synced)
        #expect(f.server.counts().creates == 1)
    }

    @Test func changedCodeIsNotAcknowledgedAndOwnPendingUploadIsNotPaintedAsConflict() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        f.server.normalizeCodeBlocksOnWrite(damageContent: true)
        let original = try await f.repo.save(NoteRecord(title: "Mermaid", notebookID: "book", markdown: "```mermaid\nA --> B[Preview]\n```"))
        await f.coordinator.push()
        let pending = try #require(try await f.repo.note(id: original.id))
        #expect(pending.syncState == .failed && pending.conflictHTML == nil)
        let remote = try await f.client.fetch(noteID: try #require(pending.remoteID))
        var incoming = NoteRecord(title: remote.summary.title, notebookID: "book", mode: .original)
        incoming.remoteID = remote.summary.id; incoming.serverVersion = remote.summary.version; incoming.originalHTML = remote.html
        let merged = try await f.repo.mergeRemote(incoming)
        #expect(merged.syncState == .failed && merged.conflictHTML == nil)
        #expect(merged.markdown == original.markdown)
    }
    @Test func recoveredCreateIDIsReboundAfterCrashBetweenJournalAndRepository() async throws {
        let f = try await ProductionFixture.make(loseCreate: true); defer { f.close() }
        let note = try await f.repo.save(NoteRecord(title: "binding crash", notebookID: "book", markdown: "draft"))
        await f.coordinator.push()
        let path = try #require(FileManager.default.contentsOfDirectory(at: f.journal, includingPropertiesForKeys: nil).first)
        var journal = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        journal["remoteID"] = "remote-1"
        try JSONSerialization.data(withJSONObject: journal).write(to: path, options: .atomic)
        let transport = try NoteStationSyncTransport(client: f.client, repository: f.repo, assets: f.assets, directory: f.journal)
        let attempt = try #require(try await f.repo.syncAttempts().first)
        _ = try await transport.reconcile(attempt)
        #expect(try await f.repo.note(id: note.id)?.remoteID == "remote-1")
        #expect(f.server.counts().creates == 1)
    }
    @Test func realTransportCreatesAndUpdatesWithoutAccumulatingManagedSources() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        var note = NoteRecord(title: "합성 문서", notebookID: "book", markdown: "# 시작\n")
        let asset = try await f.assets.importData(Data([0, 1, 2, 255]), name: "파일.bin")
        note.attachments = [asset]; note.markdown += "\n[파일](\(asset.reference))\n"
        note = try await f.repo.save(note)
        await f.coordinator.push()
        note = try #require(try await f.repo.note(id: note.id))
        #expect(note.syncState == .synced)
        #expect(f.server.counts().creates == 1)
        note.title = "수정한 제목"; note.markdown += "\n둘째 줄\n"; note.tags = ["태그"]; note.isFavorite = true
        note = try await f.repo.save(note)
        await f.coordinator.push()
        let saved = try #require(try await f.repo.note(id: note.id))
        #expect(saved.syncState == .synced)
        #expect(f.server.counts().creates == 1)
        let remote = try await f.client.fetch(noteID: saved.remoteID!)
        #expect(remote.summary.title == note.title && remote.summary.tags == ["태그"])
        #expect(remote.attachments.count == 2) // one user file, one current source
        #expect(remote.html.contains("method=download"))
        #expect(remote.html.contains(asset.id.uuidString))
        #expect(try await f.repo.syncAttempts().isEmpty)
    }

    @Test func lostPublicationResponseReconcilesWithNoSecondCreate() async throws {
        let f = try await ProductionFixture.make(losePublication: true); defer { f.close() }
        let note = try await f.repo.save(NoteRecord(title: "응답 유실", notebookID: "book", markdown: "# 보존"))
        await f.coordinator.push()
        #expect(try await f.repo.syncAttempts().count == 1)
        let restartedTransport = try NoteStationSyncTransport(client: f.client, repository: f.repo, assets: f.assets, directory: f.journal)
        let restarted = SyncCoordinator(repository: f.repo, attachments: f.assets, transport: restartedTransport)
        await restarted.push()
        #expect(try await f.repo.note(id: note.id)?.syncState == .synced)
        #expect(f.server.counts().creates == 1)
        #expect(try await f.repo.syncAttempts().isEmpty)
    }

    @Test func lostCreateResponseResumesPublicationWithoutCreatingAgain() async throws {
        let f = try await ProductionFixture.make(loseCreate: true); defer { f.close() }
        var draft = NoteRecord(title: "Lost create receipt", notebookID: "book")
        let file = try await f.assets.importData(Data("original bytes".utf8), name: "file.txt")
        draft.attachments = [file]
        draft.markdown = "# Draft\n\n[File](\(file.reference))"
        let note = try await f.repo.save(draft)

        await f.coordinator.push()
        #expect(try await f.repo.syncAttempts().count == 1)
        await f.coordinator.push()

        let saved = try #require(try await f.repo.note(id: note.id))
        #expect(f.server.counts().creates == 1)
        #expect(saved.syncState == .synced)
        #expect(saved.markdown == draft.markdown)
        #expect(saved.attachments.first?.remoteID != nil)
        #expect(try await f.repo.syncAttempts().isEmpty)
    }

    @Test func lostCreateResponseDoesNotOverwriteConcurrentlyEditedStagedNote() async throws {
        let f = try await ProductionFixture.make(loseCreate: true); defer { f.close() }
        let draft = try await f.repo.save(NoteRecord(title: "Edited elsewhere", notebookID: "book", markdown: "# Draft"))
        await f.coordinator.push()
        let staged = try #require(try await f.client.notes().first)
        let changed = "<p>Edited on another device</p>"
        _ = try await f.client.applyWrite(NoteStationWrite(objectID: staged.id, baseVersion: staged.version, html: changed))

        await f.coordinator.push()
        await f.coordinator.push()

        #expect(f.server.counts().creates == 1)
        #expect(f.server.counts().sets == 1)
        #expect(try await f.client.fetch(noteID: staged.id).html == changed)
        #expect(try await f.repo.note(id: draft.id)?.markdown == "# Draft")
        #expect(try await f.repo.syncAttempts().count == 1)
    }

    @Test func reconciliationPublishesNewerEditBeforeReportingBatchComplete() async throws {
        let f = try await ProductionFixture.make(loseCreate: true); defer { f.close() }
        var draft = try await f.repo.save(NoteRecord(title: "Edited while uploading", notebookID: "book", markdown: "# First"))
        await f.coordinator.push()
        draft.markdown = "# Latest"
        let revised = try await f.repo.save(draft)
        await f.coordinator.push { processed, total in
            if processed == total {
                let saved = try? await f.repo.note(id: revised.id)
                #expect(saved?.syncState == .synced)
            }
        }

        let saved = try #require(try await f.repo.note(id: revised.id))
        #expect(saved.syncState == .synced)
        let remote = try await f.client.fetch(noteID: try #require(saved.remoteID))
        #expect(remote.html.contains("Latest"))
        #expect(f.server.counts().creates == 1)
    }

    @Test func serverConflictDuringBodyWritePreservesLocalDraft() async throws {
        let f = try await ProductionFixture.make(conflictBody: true); defer { f.close() }
        let note = try await f.repo.save(NoteRecord(title: "충돌", notebookID: "book", markdown: "이 Mac의 초안"))
        await f.coordinator.push()
        let saved = try #require(try await f.repo.note(id: note.id))
        #expect(saved.syncState == .conflict)
        #expect(saved.markdown == "이 Mac의 초안")
        #expect(saved.conflictHTML == "<p>다른 Mac에서 수정</p>")
        #expect(saved.remoteID != nil)
        #expect(try await f.repo.syncAttempts().isEmpty)
    }

    @Test func originalMetadataUpdateNeverRewritesBodyOrAttachments() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        var markdown = try await f.repo.save(NoteRecord(title: "원본", notebookID: "book", markdown: "# 내용"))
        await f.coordinator.push()
        markdown = try #require(try await f.repo.note(id: markdown.id))
        let before = try await f.client.fetch(noteID: markdown.remoteID!)
        markdown.mode = .original; markdown.title = "제목만 변경"; markdown.isFavorite = true
        _ = try await f.repo.save(markdown)
        await f.coordinator.push()
        let after = try await f.client.fetch(noteID: markdown.remoteID!)
        #expect(before.html == after.html)
        #expect(before.attachments.map(\.id) == after.attachments.map(\.id))
        #expect(try await f.repo.note(id: markdown.id)?.syncState == .synced)
    }

    @Test func originalHTMLBodyEditUploadsAndKeepsExistingAttachments() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        var note = try await f.repo.save(NoteRecord(title: "서식 편집", notebookID: "book", markdown: "기존 본문"))
        await f.coordinator.push()
        note = try #require(try await f.repo.note(id: note.id))
        let before = try await f.client.fetch(noteID: try #require(note.remoteID))
        note.mode = .original
        note.originalHTML = "<p style=\"color: red\">새 <strong>본문</strong></p><table><tr><td>한글</td></tr></table>"
        _ = try await f.repo.save(note)
        await f.coordinator.push()
        let after = try await f.client.fetch(noteID: try #require(note.remoteID))
        #expect(after.html == note.originalHTML)
        #expect(after.attachments.map(\.id) == before.attachments.map(\.id))
        #expect(try await f.repo.note(id: note.id)?.syncState == .synced)
    }

    @Test func mathImagesUploadAsOrdinaryImagesAndRestoreExactSource() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        let markdown = #"인라인 \(\frac{a_1}{b_2}\) 와 $$x \\ y$$"#
        var note = NoteRecord(title: "수식", notebookID: "book", markdown: markdown)
        for formula in MathExport.formulas(in: markdown) {
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQzrvzH4QZYAwAUT4JsSqASqYAAAAASUVORK5CYII=")!
            var asset = try await f.assets.importData(png, name: "synology-note-math-\(formula.key).png")
            asset.generatedMath = MathAttachmentMetadata(key: formula.key, width: 32, height: 24)
            note.attachments.append(asset)
        }
        note = try await f.repo.save(note)
        await f.coordinator.push()
        let saved = try #require(try await f.repo.note(id: note.id))
        #expect(saved.syncState == .synced)
        let remote = try await f.client.fetch(noteID: try #require(saved.remoteID))
        let dom = try SwiftSoup.parseBodyFragment(remote.html)
        #expect(try dom.select("img[ref]").count == 2)
        #expect(try dom.select("script,.note-math").isEmpty())
        #expect(saved.markdown == markdown)
        #expect(saved.attachments.filter { $0.generatedMath != nil }.count == 2)
        let downloaded = try await SynologyNote.LibraryStore.downloadedRecord(noteID: remote.summary.id, client: f.client, repo: f.repo, assets: f.assets)
        #expect(downloaded.markdown == markdown)
        #expect(downloaded.attachments.filter { $0.generatedMath != nil }.count == 2)
    }

    @Test func originalDocumentCanAddImageWithoutChangingExistingTable() async throws {
        let f = try await ProductionFixture.make(); defer { f.close() }
        var note = try await f.repo.save(NoteRecord(title: "이미지 추가", notebookID: "book", markdown: "기존"))
        await f.coordinator.push()
        note = try #require(try await f.repo.note(id: note.id))
        let image = try await f.assets.importData(Data("image-payload".utf8), name: "added.png")
        note.mode = .original
        note.originalHTML = "<table><tr><td style=\"color: red\">원본 표</td></tr></table><p><img src=\"\(image.reference)\" alt=\"추가\"></p>"
        note.attachments.append(image)
        _ = try await f.repo.save(note)
        await f.coordinator.push()
        let saved = try #require(try await f.repo.note(id: note.id))
        #expect(saved.syncState == .synced, "\(saved.lastError ?? "")")
        let remote = try await f.client.fetch(noteID: try #require(saved.remoteID))
        #expect(remote.html.contains("<table><tr><td style=\"color: red\">원본 표</td></tr></table>"))
        let file = try #require(remote.attachments.first { $0.name == "added.png" })
        #expect(try await f.client.download(fileID: file.id, noteID: remote.summary.id) == Data("image-payload".utf8))
        #expect(!remote.html.contains("attachment://"))
    }

    @Test @MainActor func actualRenderedMathIsReusedAndObsoleteImageIsRemoved() async throws {
        let f = try await ProductionFixture.make(mathRenderer: MathImageRenderer()); defer { f.close() }
        var note = try await f.repo.save(NoteRecord(title: "수식 왕복", notebookID: "book", markdown: #"\(\frac{a}{b}\) 와 $x_1$"#))
        await f.coordinator.push()
        note = try #require(try await f.repo.note(id: note.id))
        #expect(note.syncState == .synced, "\(note.lastError ?? "")")
        let initial = note.attachments.filter { $0.generatedMath != nil }
        #expect(initial.count == 2)
        note.title = "제목만 수정"
        _ = try await f.repo.save(note); await f.coordinator.push()
        note = try #require(try await f.repo.note(id: note.id))
        #expect(Set(note.attachments.filter { $0.generatedMath != nil }.compactMap(\.remoteID)) == Set(initial.compactMap(\.remoteID)))
        note.markdown = #"\(\frac{a}{b}\)"#
        _ = try await f.repo.save(note); await f.coordinator.push()
        note = try #require(try await f.repo.note(id: note.id))
        #expect(note.syncState == .synced, "\(note.lastError ?? "")")
        #expect(note.attachments.filter { $0.generatedMath != nil }.count == 1)
        let remote = try await f.client.fetch(noteID: try #require(note.remoteID))
        #expect(remote.attachments.filter { $0.name.hasPrefix("synology-note-math-") }.count == 1)
        let webHTML = remote.html + "<p>웹에서 이어 쓴 본문</p>"
        _ = try await f.client.update(noteID: remote.summary.id, baseVersion: remote.summary.version, title: note.title, html: webHTML)
        let incoming = try await LibraryStore.downloadedRecord(noteID: remote.summary.id, client: f.client, repo: f.repo, assets: f.assets)
        #expect(incoming.mode == .original)
        #expect(incoming.originalHTML == webHTML)
        #expect(AttachmentResolver.previewHTML(incoming.originalHTML, attachments: incoming.attachments).contains("attachment://"))
    }
}

final class ProductionFixture {
    let root: URL, journal: URL, repo: NoteRepository, assets: AttachmentStore
    let server: ProductionNAS, client: NoteStationClient, coordinator: SyncCoordinator
    private init(root: URL, server: ProductionNAS, client: NoteStationClient, mathRenderer: (any MathImageRendering)?) throws {
        self.root = root; self.server = server; self.client = client
        repo = try NoteRepository(directory: root); assets = try AttachmentStore(directory: root.appendingPathComponent("assets"))
        journal = root.appendingPathComponent("journal")
        coordinator = SyncCoordinator(repository: repo, attachments: assets,
            transport: try NoteStationSyncTransport(client: client, repository: repo, assets: assets, directory: journal), mathRenderer: mathRenderer)
    }
    static func make(losePublication: Bool = false, loseCreate: Bool = false, conflictBody: Bool = false, mathRenderer: (any MathImageRendering)? = nil) async throws -> ProductionFixture {
        let server = ProductionNAS(losePublication: losePublication, loseCreate: loseCreate, conflictBody: conflictBody)
        let client = NoteStationClient(baseURL: URL(string: "https://\(server.host)")!, session: server.session, allowsValidatedWrites: true)
        try await client.connect(username: "test", password: "test")
        return try ProductionFixture(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), server: server, client: client, mathRenderer: mathRenderer)
    }
    func close() { server.close(); try? FileManager.default.removeItem(at: root) }
}

final class ProductionNAS: @unchecked Sendable {
    struct File { var name: String; var ref: String?; var bytes: Data }
    struct Note {
        var id: String; var title: String; var parent: String; var html: String
        var version = 1; var tags: [String] = []; var recycle = false; var files: [String: File] = [:]
        var row: [String: Any] { ["object_id": id, "title": title, "parent_id": parent, "content": html, "ver": "v\(version)", "mtime": 1700000000,
            "tag": tags, "recycle": recycle, "encrypt": false, "attachment": files.mapValues { file -> [String: Any] in
                var result: [String: Any] = ["name": file.name]; if let ref = file.ref { result["ref"] = ref }; return result
            }] }
    }
    let host = "sync-\(UUID().uuidString.lowercased()).invalid", session: URLSession
    private let lock = NSLock()
    private var notes: [String: Note] = [:], favorites: Set<String> = []
    private var books = ["book": "NAS"]
    private var creates = 0, sets = 0, fileCounter = 0
    private var normalizeCode = false, damageCode = false, loseDelete = false, keepDelete = false, deletes = 0
    private var reads = 0
    private var downloads: [String] = []
    func downloadedNames() -> [String] { lock.lock(); defer { lock.unlock() }; return downloads }
    func readCount() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
    func normalizeCodeBlocksOnWrite(damageContent: Bool = false) { lock.lock(); normalizeCode = true; damageCode = damageContent; lock.unlock() }
    func loseNextDeleteResponse() { lock.lock(); loseDelete = true; lock.unlock() }
    func keepNoteOnNextDelete() { lock.lock(); keepDelete = true; lock.unlock() }
    func deleteCount() -> Int { lock.lock(); defer { lock.unlock() }; return deletes }
    private var downloadFailures: Set<String> = []
    func failDownloads(for noteID: String) { lock.lock(); downloadFailures.insert(noteID); lock.unlock() }
    private var losePublication: Bool, loseCreate: Bool, conflictBody: Bool
    init(losePublication: Bool, loseCreate: Bool, conflictBody: Bool) {
        self.losePublication = losePublication; self.loseCreate = loseCreate; self.conflictBody = conflictBody
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProductionURLProtocol.self]
        session = URLSession(configuration: config); ProductionURLProtocol.register(self)
    }
    func close() { ProductionURLProtocol.unregister(host); session.invalidateAndCancel() }
    func counts() -> (creates: Int, sets: Int) { lock.lock(); defer { lock.unlock() }; return (creates, sets) }
    func reply(_ request: URLRequest) -> (Data, Bool) {
        lock.lock(); defer { lock.unlock() }
        var params = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
        let multipart = request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/") == true
        let parts = multipart ? multipartTestParts(request) : []
        if multipart { for part in parts where part.filename == nil { params[part.name] = String(decoding: part.data, as: UTF8.self) } }
        else {
            var form = URLComponents(); form.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            for field in form.queryItems ?? [] { params[field.name] = field.value }
        }
        func value(_ key: String) -> Any? { params[key].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) } }
        func string(_ key: String) -> String? { (value(key) as? String) ?? params[key] }
        func response(_ data: [String: Any], lost: Bool = false) -> (Data, Bool) { (try! JSONSerialization.data(withJSONObject: ["success": true, "data": data]), lost) }
        func error(_ code: Int) -> (Data, Bool) { (Data("{\"success\":false,\"error\":{\"code\":\(code)}}".utf8), false) }
        let api = params["api"], method = params["method"]
        if api == "SYNO.API.Info" {
            return response(["SYNO.API.Auth": ["path":"auth.cgi", "minVersion":1, "maxVersion":7],
                "SYNO.NoteStation.Note": ["path":"entry.cgi", "minVersion":1, "maxVersion":3, "requestFormat":"JSON"],
                "SYNO.NoteStation.Notebook": ["path":"entry.cgi", "minVersion":1, "maxVersion":2, "requestFormat":"JSON"],
                "SYNO.NoteStation.Shortcut": ["path":"entry.cgi", "minVersion":1, "maxVersion":1, "requestFormat":"JSON"]])
        }
        if api == "SYNO.API.Auth" { return response(["sid":"synthetic-sid"]) }
        if api == "SYNO.NoteStation.Notebook" {
            if method == "list" { return response(["offset":0, "total":books.count, "notebooks":books.map { ["object_id":$0.key, "title":$0.value] }]) }
            if method == "create", let title = string("title") {
                let id = "book-\(books.count + 1)"; books[id] = title
                return response(["object_id":id, "ver":"b1"])
            }
            if method == "delete", let id = string("object_id"), value("recursive") as? Bool == false {
                books.removeValue(forKey: id)
                for key in Array(notes.keys) where notes[key]?.parent == id { notes[key]?.recycle = true }
                return response([:])
            }
        }
        if api == "SYNO.NoteStation.Shortcut" {
            if method == "list" { return response(["offset":0, "total":favorites.count, "shortcuts":favorites.map { ["id":$0, "category":"note"] }]) }
            if let id = string("object_id") { if method == "set" { favorites.insert(id) } else { favorites.remove(id) } }
            return (Data(#"{"success":true}"#.utf8), false) // Shortcut writes can return success without data
        }
        guard api == "SYNO.NoteStation.Note" else { return error(102) }
        if method == "delete", let id = string("object_id"), value("recycle") as? Bool == false {
            guard notes[id]?.recycle == true else { return error(121) }
            if keepDelete { keepDelete = false; deletes += 1; return response([:]) }
            deletes += 1; notes.removeValue(forKey: id); favorites.remove(id)
            let lost = loseDelete; loseDelete = false
            return response([:], lost: lost)
        }
        if method == "list" { return response(["offset":0, "total":notes.count, "notes":notes.values.map(\.row)]) }
        if method == "get", let id = string("object_id"), let note = notes[id] { reads += 1; return response(note.row) }
        if method == "download", let id = string("object_id"), let file = string("file_id"), let asset = notes[id]?.files[file] {
            downloads.append(asset.name)
            if downloadFailures.contains(id) { return error(114) }
            return (asset.bytes, false)
        }
        if method == "create" || method == "set" {
            var note: Note
            if method == "create" {
                creates += 1
                note = Note(id: "remote-\(creates)", title: string("title") ?? "", parent: string("parent_id") ?? "", html: string("content") ?? "")
            } else {
                guard let id = string("object_id"), var current = notes[id] else { return error(114) }
                if conflictBody, params["content"] != nil {
                    conflictBody = false; current.version += 1; current.html = "<p>다른 Mac에서 수정</p>"; notes[id] = current
                }
                guard string("ver") == "v\(current.version)", value("check_conflict") as? Bool == true else { return error(1064) }
                sets += 1; note = current; note.version += 1
            }
            if let title = string("title") { note.title = title }
            if let parent = string("parent_id") { note.parent = parent }
            if let html = string("content") {
                note.html = html
                if normalizeCode, html.contains("<pre>") {
                    note.html = html.replacingOccurrences(of: " class=\"language-mermaid\"", with: "")
                        .replacingOccurrences(of: "<pre><code>", with: "<pre>")
                        .replacingOccurrences(of: "</code></pre>", with: "</pre>")
                        .replacingOccurrences(of: "&gt;", with: "&#62;")
                    if damageCode { note.html = note.html.replacingOccurrences(of: "B[Preview]", with: "C[Changed]") }
                }
            }
            if let tags = value("tag") as? [String] { note.tags = tags }
            if let recycle = value("recycle") as? Bool { note.recycle = recycle }
            var publication = false
            for entry in value("attachment") as? [[String: Any]] ?? [] {
                if entry["action"] as? String == "delete", let id = entry["file_id"] as? String { note.files.removeValue(forKey: id) }
                if entry["action"] as? String == "create", let name = entry["name"] as? String,
                   let part = parts.first(where: { $0.name == name }), let filename = part.filename {
                    fileCounter += 1; note.files["file-\(fileCounter)"] = File(name: filename, ref: entry["ref"] as? String, bytes: part.data)
                    if let envelope = try? SourceEnvelope.decode(part.data), !envelope.isStaging { publication = true }
                }
            }
            notes[note.id] = note
            var lost = false
            if method == "create", loseCreate { loseCreate = false; lost = true }
            if publication, losePublication { losePublication = false; lost = true }
            let receipt: [String: Any] = ["object_id": note.id, "ver":"v\(note.version)"]
            return response(method == "create" ? receipt : ["data":[receipt]], lost: lost)
        }
        return error(103)
    }
}

final class ProductionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock(); private static var servers: [String: ProductionNAS] = [:]
    static func register(_ server: ProductionNAS) { lock.lock(); defer { lock.unlock() }; servers[server.host] = server }
    static func unregister(_ host: String) { lock.lock(); defer { lock.unlock() }; servers.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let server = Self.servers[request.url?.host ?? ""]; Self.lock.unlock()
        guard let server, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
            while true { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; bytes.append(buffer,count:n) }
        }
        var captured = request; captured.httpBody = bytes
        let (body, lost) = server.reply(captured)
        if lost { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
