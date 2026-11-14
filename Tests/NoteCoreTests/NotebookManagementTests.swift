import Foundation
import Testing
@testable import NoteCore
@testable import SynologyNote

@Suite struct NotebookManagementTests {
    @MainActor @Test func validationNotebookIsDedicatedAndReusedAcrossStoreRestarts() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ConnectionProfile(server: "https://\(server.host)", username: "user")
        let store = try LibraryStore(root: root, profile: profile)
        store.client = client; store.isConnected = true
        try await store.repository.setNotebooks([Notebook(id: "personal", name: "개인 메모장")])
        server.books([("personal", "개인 메모장")])
        server.json(["object_id": "probe-book"]) { fields in
            #expect(fields["method"] == "create")
            #expect(fields["title"]?.contains("SynologyNote 검사") == true)
        }
        // The returned notebook must be separately created, then confirmed in NAS.
        let probeName = try await store.validationNotebookName()
        server.books([("personal", "개인 메모장"), ("probe-book", probeName)])
        let created = try await store.ensureNASValidationNotebook()
        #expect(created.id == "probe-book")
        #expect(created.name == probeName)
        #expect(store.notebooks.contains(where: { $0.id == "personal" }))

        let reopened = try LibraryStore(root: root, profile: profile)
        reopened.client = client; reopened.isConnected = true
        server.books([("personal", "개인 메모장"), ("probe-book", probeName)])
        let reused = try await reopened.ensureNASValidationNotebook()
        #expect(reused.id == "probe-book")
        #expect(server.requests.filter { $0["method"] == "create" }.count == 1)
        server.assertConsumed()
    }

    @MainActor @Test func uncertainValidationNotebookCreateNeverCreatesSecondNotebook() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://\(server.host)", username: "user"))
        store.client = client; store.isConnected = true
        server.books([]); server.lost()
        await #expect(throws: NoteStationError.notebookWriteUncertain(objectID: nil)) {
            try await store.ensureNASValidationNotebook()
        }
        await #expect(throws: NoteStationError.notebookWriteUncertain(objectID: nil)) {
            try await store.ensureNASValidationNotebook()
        }
        #expect(server.requests.filter { $0["method"] == "create" }.count == 1)
        server.assertConsumed()
    }

    @MainActor @Test func validationNotebookNeverAdoptsExistingNotebookWithSameName() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://\(server.host)", username: "user"))
        store.client = client; store.isConnected = true
        let probeName = try await store.validationNotebookName()
        server.books([("someone-else", probeName)])
        await #expect(throws: NoteStationError.invalidArgument("duplicate notebook name")) {
            try await store.ensureNASValidationNotebook()
        }
        #expect(!server.requests.contains(where: { $0["method"] == "create" }))
        server.assertConsumed()
    }

    @MainActor @Test func validationNotebookNamesAreIsolatedByAccountAndInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        let profile = ConnectionProfile(server: "https://example.invalid", username: "user")
        let first = try LibraryStore(root: root, profile: profile)
        let otherAccount = try LibraryStore(root: root, profile: ConnectionProfile(server: profile.server, username: "other"))
        let otherInstallation = try LibraryStore(root: otherRoot, profile: profile)
        let name = try await first.validationNotebookName()
        #expect(name == (try await first.validationNotebookName()))
        #expect(name != (try await otherAccount.validationNotebookName()))
        #expect(name != (try await otherInstallation.validationNotebookName()))
    }

    @Test func deleteUsesNonRecursiveOfficialContractAndConfirmsRemoval() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.books([("book", "name")])
        server.json([:]) { fields in
            #expect(fields["method"] == "delete" && fields["version"] == "2")
            #expect(fields["object_id"] == #""book""#)
            #expect(fields["recursive"] == "false")
        }
        server.books([])
        try await client.deleteNotebook(notebookID: "book")
        server.assertConsumed()
    }

    @Test func lostDeleteResponseReconcilesWithoutRepeatingDelete() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.books([("book", "name")]); server.lost(); server.books([])
        try await client.deleteNotebook(notebookID: "book")
        #expect(server.requests.filter { $0["method"] == "delete" }.count == 1)
        server.assertConsumed()
    }

    @Test func deleteDoesNotClaimSuccessWhenReadbackStillContainsNotebook() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.books([("book", "name")]); server.successOnly(); server.books([("book", "name")])
        await #expect(throws: NoteStationError.invalidResponse) { try await client.deleteNotebook(notebookID: "book") }
        server.assertConsumed()
    }

    @MainActor @Test func migrationPreservesDraftIDAndBodyAndQueuesNASUpload() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://\(server.host)", username: "user"))
        store.client = client; store.isConnected = true
        try await store.repository.setNotebooks([Notebook(id: "local-old", name: "markdown")])
        let note = try await store.repository.save(NoteRecord(title: "Test", notebookID: "local-old", markdown: "# 제목\n- 안녕?"), enqueue: false)
        let session = try #require(await store.session(for: note.id))
        server.books([("book", "markdown")])
        try await store.migrateLegacyNotebooks()
        let moved = try #require(try await store.repository.note(id: note.id))
        #expect(moved.notebookID == "book" && moved.markdown == note.markdown)
        #expect(moved.syncState == .pending && session.note.notebookID == "book")
        #expect(try await store.repository.pendingOperations().map(\.noteID) == [note.id])
        #expect(store.notebooks.map(\.id) == ["book"])
        #expect(!server.requests.contains { $0["method"] == "create" })
        server.assertConsumed()
    }

    @MainActor @Test func deletingNotebookWithPendingDraftNeverSendsDelete() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://\(server.host)", username: "user"))
        store.client = client; store.isConnected = true
        _ = try await store.repository.save(NoteRecord(notebookID: "book", markdown: "pending"))
        await #expect(throws: RepositoryError.self) { try await store.deleteNotebook(id: "book") }
        #expect(!server.requests.contains { $0["method"] == "delete" })
        server.assertConsumed()
    }

    @Test func renameConfirmsKnownTargetWithSuccessOnlyOrNestedReceipt() async throws {
        for empty in [true, false] {
            let server = ManagementNAS(); defer { server.close() }
            let client = try await server.connectedClient()
            if empty { server.successOnly() }
            else { server.json(["data": [["object_id": "book", "ver": "b2"]]]) }
            server.books([("book", "renamed")])
            #expect(try await client.renameNotebook(notebookID: "book", name: "renamed").name == "renamed")
            #expect(server.requests.filter { $0["method"] == "set" }.count == 1)
            server.assertConsumed()
        }
    }
    @Test func writesRequireValidatedContract() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = server.client(writes: false)
        await #expect(throws: NoteStationError.writeContractUnvalidated) { try await client.createNotebook(name: "새 책") }
        await #expect(throws: NoteStationError.writeContractUnvalidated) { try await client.renameNotebook(notebookID: "book", name: "다른 책") }
        #expect(server.requests.isEmpty)
    }
    @Test func createAndRenameUseOfficialV2FieldsAndConfirmReadback() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.books([])
        server.json(["object_id": "created", "ver": "b1", "ctime": 1700000000]) { fields in
            #expect(fields["method"] == "create" && fields["version"] == "2")
            #expect(fields["title"] == #""새 책""#)
            #expect(fields["commit_msg"] == #"{"device":"desktop"}"#)
            #expect(fields["local_id"] == nil)
        }
        server.books([("created", "새 책")])
        let book = try await client.createNotebook(name: "  새 책  ")
        #expect(book.id == "created" && book.name == "새 책")
        server.json(["object_id": "created", "ver": "b2", "ctime": 1700000000, "mtime": 1700000001]) { fields in
            #expect(fields["method"] == "set" && fields["version"] == "2")
            #expect(fields["object_id"] == #""created""# && fields["title"] == #""이름 변경""#)
            #expect(fields["ver"] == nil && fields["check_conflict"] == nil)
        }
        server.books([("created", "이름 변경")])
        #expect(try await client.renameNotebook(notebookID: "created", name: "이름 변경").name == "이름 변경")
        server.assertConsumed()
    }
    @Test func lostCreateCannotBeRetriedEvenAfterManagerRestart() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        server.books([]); server.lost()
        let manager = try NotebookCreationManager(directory: directory)
        await #expect(throws: NoteStationError.notebookWriteUncertain(objectID: nil)) { try await manager.create(name: "lost", client: client) }
        let restarted = try NotebookCreationManager(directory: directory)
        await #expect(throws: NoteStationError.notebookWriteUncertain(objectID: nil)) { try await restarted.create(name: "lost", client: client) }
        #expect(server.requests.filter { $0["method"] == "create" }.count == 1)
        server.assertConsumed()
    }
    @Test func lostReadbackRetainsAcknowledgedIDAndRetriesReadOnly() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.books([]); server.json(["object_id": "created", "ver": "b1"]); server.lost()
        await #expect(throws: NoteStationError.notebookWriteUncertain(objectID: "created")) { try await client.createNotebook(name: "new") }
        server.books([("created", "new")])
        #expect(try await client.createNotebook(name: "new").id == "created")
        #expect(server.requests.filter { $0["method"] == "create" }.count == 1)
        server.assertConsumed()
    }
    @Test func existingNameAndEmptyNameNeverCreate() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        await #expect(throws: NoteStationError.invalidArgument("name")) { try await client.createNotebook(name: " \n ") }
        server.books([("existing", "duplicate")])
        await #expect(throws: NoteStationError.invalidArgument("duplicate notebook name")) { try await client.createNotebook(name: "duplicate") }
        #expect(!server.requests.contains { $0["method"] == "create" })
        server.assertConsumed()
    }
    @Test func expiredSessionIsObservableAfterAPIError() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        #expect(await client.isAuthenticated)
        server.error(code: 119)
        await #expect(throws: NoteStationError.sessionExpired) { try await client.notebooks() }
        #expect(await !client.isAuthenticated)
    }
}

final class ManagementNAS: @unchecked Sendable {
    struct Reply { var body: Data; var lost = false; var check: ([String: String]) -> Void = { _ in } }
    let host = "management-\(UUID().uuidString.lowercased()).invalid"
    let session: URLSession
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var captured: [[String: String]] = []
    var requests: [[String: String]] { lock.lock(); defer { lock.unlock() }; return captured }
    init() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ManagementURLProtocol.self]
        session = URLSession(configuration: config); ManagementURLProtocol.register(self)
    }
    func close() { ManagementURLProtocol.unregister(host); session.invalidateAndCancel() }
    func client(writes: Bool = true) -> NoteStationClient { NoteStationClient(baseURL: URL(string: "https://\(host)")!, session: session, allowsValidatedWrites: writes) }
    func connectedClient() async throws -> NoteStationClient {
        let info: [String: Any] = ["SYNO.API.Auth": ["path":"auth.cgi","minVersion":1,"maxVersion":6],
            "SYNO.NoteStation.Note": ["path":"entry.cgi","minVersion":1,"maxVersion":3],
            "SYNO.NoteStation.Info": ["path":"entry.cgi","minVersion":1,"maxVersion":2],
            "SYNO.NoteStation.Stack": ["path":"entry.cgi","minVersion":1,"maxVersion":1],
            "SYNO.NoteStation.Notebook": ["path":"entry.cgi","minVersion":1,"maxVersion":99]]
        json(info); json(["sid":"synthetic"]); json(info)
        let client = client(); try await client.connect(username: "synthetic", password: "synthetic"); return client
    }
    func books(_ rows: [(String, String)]) { json(["offset":0,"total":rows.count,"notebooks":rows.map { ["object_id":$0.0,"title":$0.1] }]) }
    func stackedBooks(_ rows: [(String, String, String)]) {
        json(["offset":0,"total":rows.count,"notebooks":rows.map { ["object_id":$0.0,"title":$0.1,"stack":$0.2] }])
    }
    func json(_ data: [String: Any], check: @escaping ([String: String]) -> Void = { _ in }) {
        enqueue(Reply(body: try! JSONSerialization.data(withJSONObject: ["success":true,"data":data]), check: check))
    }
    func lost() { enqueue(Reply(body: Data(), lost: true)) }
    func successOnly() { enqueue(Reply(body: Data(#"{"success":true}"#.utf8))) }
    func error(code: Int) { enqueue(Reply(body: Data("{\"success\":false,\"error\":{\"code\":\(code)}}".utf8))) }
    private func enqueue(_ reply: Reply) { lock.lock(); defer { lock.unlock() }; replies.append(reply) }
    func next(_ fields: [String: String]) -> Reply? {
        lock.lock(); defer { lock.unlock() }; captured.append(fields)
        guard !replies.isEmpty else { Issue.record("Unexpected network request"); return nil }; return replies.removeFirst()
    }
    func assertConsumed() { lock.lock(); defer { lock.unlock() }; #expect(replies.isEmpty) }
}
private final class ManagementURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock(); private static var servers: [String: ManagementNAS] = [:]
    static func register(_ server: ManagementNAS) { lock.lock(); defer { lock.unlock() }; servers[server.host] = server }
    static func unregister(_ host: String) { lock.lock(); defer { lock.unlock() }; servers.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let server = Self.servers[request.url?.host ?? ""]; Self.lock.unlock()
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
            while true { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; data.append(buffer,count:n) }
        }
        var form = URLComponents(); form.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let fields = Dictionary(uniqueKeysWithValues: (form.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let reply = server?.next(fields), let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        reply.check(fields)
        if reply.lost { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self, didLoad: reply.body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
