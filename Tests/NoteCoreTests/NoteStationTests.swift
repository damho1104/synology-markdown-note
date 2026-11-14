import Foundation
import Security
import Testing
@testable import NoteCore
@testable import SynologyNote

// An isolated, unlocked keychain lets Security.framework round-trip tests run
// from SSH and service-based CI without accessing the user's login keychain.
private final class TemporaryTestKeychain {
    let reference: SecKeychain
    private let directory: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("synonote-keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let password = UUID().uuidString
        var created: SecKeychain?
        let status = password.withCString { pointer in
            SecKeychainCreate(directory.appendingPathComponent("test.keychain-db").path,
                              UInt32(password.utf8.count), pointer, false, nil, &created)
        }
        guard status == errSecSuccess, let created else {
            try? FileManager.default.removeItem(at: directory)
            throw CredentialStoreError.keychain(status: status)
        }
        let unlockStatus = password.withCString { pointer in
            SecKeychainUnlock(created, UInt32(password.utf8.count), pointer, true)
        }
        guard unlockStatus == errSecSuccess else {
            SecKeychainDelete(created)
            try? FileManager.default.removeItem(at: directory)
            throw CredentialStoreError.keychain(status: unlockStatus)
        }
        self.reference = created
        self.directory = directory
    }

    deinit {
        SecKeychainDelete(reference)
        try? FileManager.default.removeItem(at: directory)
    }
}

// Only synthetic data; URLProtocol intercepts every request, including unexpected ones.
@Suite struct NoteStationTests {
    @Test @MainActor func metadataActionRetriesAFailedInitialDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeNAS(); server.login()
        let client = server.client()
        try await client.connect(username: "synthetic", password: "synthetic")
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://\(server.host)", username: "synthetic"), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        store.client = client; store.isConnected = true
        var shell = NoteRecord(title: "재시도", notebookID: "book-1", mode: .original)
        shell.remoteID = "retry-note"; shell.listedVersion = "v1"; shell.hasRemoteContent = false
        try await store.repository.observeRemote(shell)
        let saved = try #require(try await store.repository.note(remoteID: "retry-note"))
        server.json(#"{"success":false,"error":{"code":114}}"#)
        let session = try #require(await store.session(for: saved.id))
        for _ in 0..<200 {
            if session.note.lastError != nil && !session.isDownloading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.note.hasRemoteContent)
        server.json(#"{"success":true,"data":{"object_id":"retry-note","title":"재시도","parent_id":"book-1","ver":"v1","mtime":1700000001,"tag":[],"encrypt":false,"recycle":false,"content":"<p>재시도 성공</p>","attachment":{}}}"#)
        server.json(#"{"success":true,"data":{"offset":0,"total":0,"shortcuts":[]}}"#)
        let ready = await store.session(for: saved.id, waitForContent: true)
        #expect(ready === session)
        if let ready { store.toggleFavorite(ready); await store.flush() }
        await store.localReloadTask?.value
        #expect(session.note.originalHTML == "<p>재시도 성공</p>")
        #expect(session.note.isFavorite && session.note.syncState == .pending)
        #expect(session.note.conflictHTML == nil)
        server.assertConsumed()
    }

    @Test(arguments: [true, false]) @MainActor func metadataActionWaitsForMissingBody(favorite: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeNAS(); server.login()
        let client = server.client()
        try await client.connect(username: "synthetic", password: "synthetic")
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://\(server.host)", username: "synthetic"), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        store.client = client; store.isConnected = true
        var shell = NoteRecord(title: "합성 문서", notebookID: "book-1", mode: .original)
        shell.remoteID = "metadata-note"; shell.listedVersion = "v1"; shell.hasRemoteContent = false
        try await store.repository.observeRemote(shell)
        let saved = try #require(try await store.repository.note(remoteID: "metadata-note"))
        let pause = ResponsePause()
        let body = #"{"success":true,"data":{"object_id":"metadata-note","title":"합성 문서","parent_id":"book-1","ver":"v1","mtime":1700000001,"tag":[],"encrypt":false,"recycle":false,"content":"<p>보존할 본문</p>","attachment":{}}}"#
        server.bytes(Data(body.utf8), contentType: "application/json", pause: pause)
        server.json(#"{"success":true,"data":{"offset":0,"total":0,"shortcuts":[]}}"#)
        // Selection already has a session whose body request is still outstanding.
        let session = try #require(await store.session(for: saved.id))
        await pause.waitUntilStarted()
        var actionFinished = false
        let action = Task {
            if let target = await store.session(for: saved.id, waitForContent: true) {
                if favorite { store.toggleFavorite(target) } else { store.toggleTrash(target) }
                await store.flush()
            }
            actionFinished = true
        }
        for _ in 0..<20 {
            if actionFinished { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!actionFinished)
        #expect(try await store.repository.pendingOperations().isEmpty)
        await pause.resume()
        await action.value
        for _ in 0..<200 {
            if !session.isDownloading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.localReloadTask?.value
        #expect(session.note.hasRemoteContent)
        #expect(session.note.originalHTML == "<p>보존할 본문</p>")
        #expect(session.note.syncState == .pending)
        #expect(session.note.conflictHTML == nil)
        #expect(favorite ? session.note.isFavorite : session.note.isTrashed)
        #expect(try await store.repository.note(id: saved.id)?.originalHTML == "<p>보존할 본문</p>")
        server.assertConsumed()
    }

    @Test @MainActor func openingNoteReturnsBeforeDelayedBodyAndCoalescesDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeNAS(); server.login()
        let client = server.client()
        try await client.connect(username: "synthetic", password: "synthetic")
        let store = try LibraryStore(root: root, profile: ConnectionProfile(), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        store.client = client; store.isConnected = true
        var shell = NoteRecord(title: "합성 문서", notebookID: "book-1", mode: .original)
        shell.remoteID = "delayed-note"; shell.serverVersion = "v1"; shell.listedVersion = "v1"
        shell.hasRemoteContent = false
        let saved = try await store.repository.save(shell, enqueue: false)
        let pause = ResponsePause()
        let body = #"{"success":true,"data":{"object_id":"delayed-note","title":"합성 문서","parent_id":"book-1","ver":"v1","mtime":1700000001,"tag":[],"encrypt":false,"recycle":false,"content":"<p>다운로드 완료</p>","attachment":{}}}"#
        server.bytes(Data(body.utf8), contentType: "application/json", pause: pause) { _, form in
            #expect(form["api"] == "SYNO.NoteStation.Note")
            #expect(form["method"] == "get")
        }
        server.json(#"{"success":true,"data":{"offset":0,"total":0,"shortcuts":[]}}"#)
        var opened: EditorSession?
        let opening = Task { opened = await store.session(for: saved.id) }
        await pause.waitUntilStarted()
        // The request is held open: selection must already have returned its session.
        #expect(opened != nil)
        #expect(opened?.isDownloading == true)
        #expect(opened?.note.hasRemoteContent == false)
        var repeatedDownload: Task<Void, Never>?
        if let opened {
            #expect(await store.session(for: saved.id) === opened)
            repeatedDownload = Task { await store.fetchContent(for: opened) }
        }
        await pause.resume()
        await repeatedDownload?.value
        await opening.value
        let session = try #require(opened)
        for _ in 0..<200 {
            if !session.isDownloading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.isDownloading)
        #expect(session.note.originalHTML == "<p>다운로드 완료</p>")
        #expect(session.note.hasRemoteContent)
        #expect(try await store.repository.note(id: saved.id)?.hasRemoteContent == true)
        #expect(store.connectionError == nil)
        server.assertConsumed()
    }

    @Test func testDiscoveryLoginUsesAdvertisedPathVersionOTPAndPercentEncoding() async throws {
        let server = FakeNAS()
        server.json(Self.authInfo)
        server.json(#"{"success":true,"data":{"sid":"synthetic-sid"}}"#) { request, form in
            expectEqual(request.url?.path, "/proxy/webapi/auth.cgi")
            expectNil(request.url?.query)
            expectEqual(request.httpMethod, "POST")
            expectEqual(form["version"], "6") // official client's tested authentication cap
            expectEqual(form["session"], "notestation")
            expectEqual(form["account"], "한글+&= user")
            expectEqual(form["passwd"], "synthetic+&=% password")
            expectEqual(form["otp_code"], "012345")
            expectEqual(form["format"], "sid")
        }
        server.json(Self.apiInfo) { _, form in
            expectEqual(form["query"], "all")
            expectEqual(form["_sid"], "synthetic-sid")
        }
        let client = server.client(prefix: "/proxy")
        try await client.connect(username: "한글+&= user", password: "synthetic+&=% password", otp: "012345")
        server.assertConsumed()
    }

    @Test func testRealNotebookAndNoteShapesPaginationAndShortcutFavorites() async throws {
        let server = FakeNAS(); server.login()
        server.json(#"{"success":true,"data":{"offset":0,"total":1,"notebooks":[{"object_id":"book-1","title":"책","owner":{"uid":1,"display_name":"synthetic"},"ver":"b1","ctime":1700000000,"mtime":1700000001,"archive":false}]}}"#) { req, form in
            expectEqual(req.url?.path, "/webapi/entry.cgi")
            expectEqual(form["version"], "2") // supported contract cap, not arbitrary server v99
        }
        server.json(#"{"success":true,"data":{"offset":0,"total":2,"notes":[{"object_id":"note-1","title":"첫 문서","parent_id":"book-1","ver":"v2","mtime":1700000001,"ctime":1700000000,"tag":["태그"],"recycle":false,"encrypt":false,"owner":{"uid":1,"display_name":"synthetic"},"perm":"owner","attachment":{},"thumb":{}}]}}"#) { _, form in
            expectEqual(form["offset"], "0")
            expectEqual(form["version"], "3")
        }
        server.json(#"{"success":true,"data":{"offset":1,"total":2,"notes":[{"object_id":"note-2","title":"잠금","parent_id":"book-1","ver":"v3","mtime":1700000002,"tag":[],"recycle":true,"encrypt":true}]}}"#) { _, form in
            expectEqual(form["offset"], "1")
        }
        server.json(#"{"success":true,"data":{"offset":0,"total":2,"shortcuts":[{"id":"note-1","category":"note","title":"첫 문서","owner":{"uid":1,"display_name":"synthetic"}},{"id":"book-1","category":"notebook","title":"책"}]}}"#)
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        let books = try await client.notebooks()
        expectEqual(books.map(\.id), ["book-1"]); expectEqual(books.first?.name, "책")
        let notes = try await client.notes()
        expectEqual(notes.count, 2)
        expectEqual(notes[0].notebookID, "book-1"); expectEqual(notes[0].version, "v2")
        expectEqual(notes[0].tags, ["태그"]); expectTrue(notes[0].isFavorite)
        expectEqual(notes[0].modifiedAt, Date(timeIntervalSince1970: 1700000001))
        expectEqual(notes[0].createdAt, Date(timeIntervalSince1970: 1700000000))
        #expect(notes[1].createdAt == nil) // Older NAS responses may omit ctime.
        expectTrue(notes[1].isLocked); expectTrue(notes[1].isTrashed)
        expectFalse(notes[1].isFavorite)
        server.assertConsumed()
    }

    @Test func testFetchUsesJSONEncodedIDAndAttachmentDictionaryAndHistoryVersionField() async throws {
        let server = FakeNAS(); server.login()
        server.json(Self.note) { _, form in
            expectEqual(form["object_id"], #""note/+&=한글""#)
            expectNil(form["ver"])
        }
        server.json(#"{"success":true,"data":{"offset":0,"total":0,"shortcuts":null}}"#)
        server.json(#"{"success":true,"data":{"offset":0,"total":1,"versions":[{"id":"revision-id","version":"revision-v1","mtime":1700000000,"author":"synthetic","commit_msg":{"device":"desktop","listable":true},"last_version":"v0"}]}}"#) { _, form in
            expectEqual(form["api"], "SYNO.NoteStation.Note.Version")
            expectEqual(form["version"], "2")
            expectEqual(form["filter"], #"{"listable":true}"#)
        }
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        let note = try await client.fetch(noteID: "note/+&=한글")
        expectEqual(note.html, "<p>합성 문서</p>")
        expectEqual(note.attachments.map(\.id), ["file-1", "file-2"])
        expectEqual(note.attachments[0].name, "synthetic.png")
        expectEqual(note.attachments[0].mimeType, "image/png")
        expectNil(note.attachments[1].mimeType)
        let history = try await client.versionHistory(noteID: "note/+&=한글")
        expectEqual(history.first?.version, "revision-v1")
        expectNil(history.first?.title) // original history API has no note-title field
        expectEqual(history.first?.modifiedAt, Date(timeIntervalSince1970: 1700000000))
        // Public Codable models use the app contract; wire fields are adapted separately.
        let roundtrip = try JSONDecoder().decode(RemoteNote.self, from: JSONEncoder().encode(note))
        expectEqual(roundtrip.summary.id, note.summary.id)
        expectEqual(roundtrip.html, note.html)
        server.assertConsumed()
    }

    @Test func testDownloadReturnsOriginalBytesAndUsesRawModeWithoutThumbnail() async throws {
        let server = FakeNAS(); server.login()
        let binary = Data([0, 1, 2, 0xFF])
        server.bytes(binary, contentType: "application/octet-stream") { request, form in
            expectNil(request.url?.query) // SID stays out of URLs
            expectEqual(form["api"], "SYNO.NoteStation.Note")
            expectEqual(form["method"], "download")
            expectEqual(form["object_id"], #""note-1""#)
            expectEqual(form["file_id"], #""file-1""#)
            expectEqual(form["format"], #""raw""#)
            expectEqual(form["mode"], #""download""#)
            expectNil(form["thumb"])
        }
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        let bytes = try await client.download(fileID: "file-1", noteID: "note-1")
        expectEqual(bytes, binary)
        server.assertConsumed()
    }

    @Test func testSessionExpiryInvalidatesSIDAndRequiresExplicitLogin() async throws {
        for code in [106, 107, 119] {
            let server = FakeNAS(); server.login()
            server.json("{\"success\":false,\"error\":{\"code\":\(code)}}")
            let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
            await assertError(.sessionExpired) { try await client.notes() }
            await assertError(.notConnected) { try await client.notebooks() }
            server.assertConsumed()
        }
    }

    @Test func testPartialFailureAfterSuccessfulCompoundResultDoesNotBecomeSuccess() async throws {
        let server = FakeNAS(); server.login()
        server.json(#"{"success":true,"data":{"has_fail":true,"result":[{"success":true,"data":{}},{"success":false,"error":{"code":119}}]}}"#)
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        await assertError(.sessionExpired) { try await client.notebooks() }
        server.assertConsumed()
    }

    @Test func testOTPAndCredentialErrorsAreTypedWithoutResponseSecrets() async throws {
        for (code, expected) in [(400, NoteStationError.authenticationFailed(code: 400)), (403, .otpRequired), (404, .invalidOTP)] {
            let server = FakeNAS(); server.json(Self.authInfo)
            server.json("{\"success\":false,\"error\":{\"code\":\(code),\"message\":\"synthetic-secret\"}}")
            let client = server.client()
            await assertError(expected) { try await client.connect(username: "synthetic", password: "synthetic-secret") }
            expectFalse(String(describing: expected).contains("synthetic-secret"))
            server.assertConsumed()
        }
    }

    @Test func testRejectsInsecureURLAndMissingIdentifiersAndGatesWritesWithoutNetwork() async throws {
        let server = FakeNAS()
        let insecure = NoteStationClient(baseURL: URL(string: "http://\(server.host)")!, session: server.session)
        await assertError(.insecureTransport) { try await insecure.connect(username: "synthetic", password: "synthetic") }
        let client = server.client()
        await assertError(.invalidArgument("noteID")) { try await client.fetch(noteID: " ") }
        await assertError(.invalidArgument("fileID")) { try await client.download(fileID: "", noteID: "note-1") }
        await assertError(.writeContractUnvalidated) { try await client.update(noteID: "note-1", baseVersion: "v1", title: "合成", html: "<p>synthetic</p>") }
        server.assertConsumed()
    }

    @Test func testValidationCreateUsesObservedContractWithoutEnablingProductionWrites() async throws {
        let server = FakeNAS(); server.login()
        server.json(#"{"success":true,"data":{"object_id":"validation-note-1","ver":"v1","ctime":1700000000,"mtime":1700000000,"owner":{"display_name":"synthetic"}}}"#) { _, form in
            expectEqual(form["api"], "SYNO.NoteStation.Note")
            expectEqual(form["method"], "create")
            expectEqual(form["version"], "3")
            expectEqual(form["title"], #""[SynologyNote 검증] abc12345""#)
            expectEqual(form["parent_id"], #""book-1""#)
            expectEqual(form["encrypt"], "false")
            expectEqual(form["content"], #""<p>marker abc12345</p>""#)
            expectEqual(form["brief"], #""SynologyNote 쓰기 호환성 검증""#)
            expectEqual(form["latitude"], "0")
            expectEqual(form["longitude"], "0")
            guard let commit = form["commit_msg"],
                  let object = try? JSONSerialization.jsonObject(with: Data(commit.utf8)) as? [String: Any] else {
                Issue.record("commit_msg must be JSON")
                return
            }
            expectEqual(object["device"] as? String, "desktop")
            expectEqual(object["listable"] as? Bool, false)
        }
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        let receipt = try await client.createValidationNote(notebookID: "book-1",
                                                            title: "[SynologyNote 검증] abc12345",
                                                            html: "<p>marker abc12345</p>")
        expectEqual(receipt.objectID, "validation-note-1")
        expectEqual(receipt.version, "v1")
        expectFalse(client.capabilities.supportsWrites)
        await assertError(.writeContractUnvalidated) {
            try await client.update(noteID: receipt.objectID, baseVersion: receipt.version,
                                    title: receipt.title, html: "<p>production write remains gated</p>")
        }
        server.assertConsumed()
    }

    @Test func testOTPRegistersTrustedDeviceWithoutReusingOldToken() async throws {
        let server = FakeNAS()
        server.json(Self.authInfo)
        server.json(#"{"success":true,"data":{"sid":"synthetic-sid","did":"fresh-device-token"}}"#) { _, form in
            expectEqual(form["version"], "6")
            expectEqual(form["enable_device_token"], "yes")
            expectEqual(form["device_name"], "SynologyNote macOS")
            expectEqual(form["otp_code"], "123456")
            expectNil(form["device_id"])
        }
        server.json(Self.apiInfo)
        let client = server.client()
        try await client.connect(username: "synthetic", password: "synthetic", otp: "123456", rememberDevice: true, deviceID: "revoked-token")
        #expect(await client.trustedDeviceID == "fresh-device-token")
        await client.disconnect()
        #expect(await client.trustedDeviceID == nil)
        server.assertConsumed()
    }

    @Test func testTrustedDeviceLoginOmitsOTPAndKeepsTokenWhenNotRotated() async throws {
        let server = FakeNAS()
        server.json(Self.authInfo)
        server.json(#"{"success":true,"data":{"sid":"synthetic-sid"}}"#) { _, form in
            expectEqual(form["device_id"], "stored-device-token")
            expectNil(form["otp_code"])
        }
        server.json(Self.apiInfo)
        let client = server.client()
        try await client.connect(username: "synthetic", password: "synthetic", rememberDevice: true, deviceID: "stored-device-token")
        #expect(await client.trustedDeviceID == "stored-device-token")
        server.assertConsumed()
    }

    @Test func testDisabledDeviceTrustDoesNotTransmitOrRetainStoredToken() async throws {
        let server = FakeNAS()
        server.json(Self.authInfo)
        server.json(#"{"success":true,"data":{"sid":"synthetic-sid","did":"unrequested-token"}}"#) { _, form in
            expectNil(form["enable_device_token"])
            expectNil(form["device_id"])
        }
        server.json(Self.apiInfo)
        let client = server.client()
        try await client.connect(username: "synthetic", password: "synthetic", rememberDevice: false, deviceID: "stored-device-token")
        #expect(await client.trustedDeviceID == nil)
        server.assertConsumed()
    }

    @Test func testTrustedCredentialBlobRoundTripAndAccountIsolation() throws {
        let fixture = try TemporaryTestKeychain()
        defer { withExtendedLifetime(fixture) {} }
        let keychain = fixture.reference
        let account = "notestation-credentials-\(UUID())"
        let credentials = SavedNASCredentials(password: "synthetic-password", deviceID: "synthetic-device-id")
        try CredentialStore.saveCredentials(credentials, account: account, testKeychain: keychain)
        #expect(try CredentialStore.loadCredentials(account: account, testKeychain: keychain) == credentials)
        #expect(try CredentialStore.load(account: account, testKeychain: keychain) == credentials.password)
        #expect(try CredentialStore.loadCredentials(account: UUID().uuidString, testKeychain: keychain) == nil)
        try CredentialStore.saveCredentials(SavedNASCredentials(password: nil, deviceID: "device-only"), account: account, testKeychain: keychain)
        #expect(try CredentialStore.load(account: account, testKeychain: keychain) == nil)
        #expect(try CredentialStore.loadCredentials(account: account, testKeychain: keychain)?.deviceID == "device-only")
    }

    @Test func testBlockedKeychainReadReturnsAtDeadlineAndIgnoresLateResult() async throws {
        let clock = ContinuousClock(), start = ContinuousClock.now
        do {
            _ = try await CredentialStore.boundedLoad(timeout: 0.03) {
                Thread.sleep(forTimeInterval: 0.2)
                return SavedNASCredentials(password: "late-result")
            }
            Issue.record("Blocked credential read did not time out")
        } catch {
            #expect(error as? CredentialStoreError == .keychain(status: -25308))
        }
        #expect(clock.now - start < .seconds(1))
        // Allow the losing operation to complete: it must not resume twice.
        try await Task.sleep(for: .milliseconds(250))
    }

    @Test func testEditingValidationUsesCreatedIDAndServerConflictCheck() async throws {
        let (server, client) = try await editingValidationServer()
        let report = try await client.validateNoteEditing(notebookID: "book-1")
        #expect(report.passed)
        #expect(report.receipt.objectID == "probe-1")
        #expect(report.updatedVersion == "v2")
        #expect(report.conflictRejected && report.latestContentPreserved)
        #expect(!client.capabilities.supportsWrites)
        await assertError(.writeContractUnvalidated) {
            try await client.update(noteID: "user-note", baseVersion: "v1", title: "untouched", html: "untouched")
        }
        server.assertConsumed()
    }

    @Test func testIgnoredConflictCannotPassEvenWithSuccessfulWriteEnvelope() async throws {
        let (server, client) = try await editingValidationServer(staleCode: nil)
        let report = try await client.validateNoteEditing(notebookID: "book-1")
        #expect(report.updateConfirmed)
        #expect(!report.passed && !report.conflictRejected && !report.latestContentPreserved)
        #expect(report.failure != nil)
        server.assertConsumed()
    }

    @Test func testUnrelatedErrorCannotBeMistakenForConflictEvenIfBodyPreserved() async throws {
        let (server, client) = try await editingValidationServer(staleCode: 120)
        let report = try await client.validateNoteEditing(notebookID: "book-1")
        #expect(!report.passed && !report.conflictRejected)
        #expect(report.latestContentPreserved)
        #expect(report.failure?.contains("120") == true)
        server.assertConsumed()
    }

    @Test func testConflictErrorAloneCannotPassWithoutLatestContent() async throws {
        let (server, client) = try await editingValidationServer(lostLatestContent: true)
        let report = try await client.validateNoteEditing(notebookID: "book-1")
        #expect(report.conflictRejected && !report.latestContentPreserved && !report.passed)
        #expect(report.failure != nil)
        server.assertConsumed()
    }

    @Test func testMalformedSetReceiptDoesNotAdvanceOrRetryProbe() async throws {
        let (server, client) = try await editingValidationServer(malformedSetReceipt: true)
        let report = try await client.validateNoteEditing(notebookID: "book-1")
        #expect(report.stage == .update && !report.passed)
        #expect(report.updatedVersion == nil && report.failure != nil)
        server.assertConsumed()
    }

    @Test func testUpdateReadbackMismatchStopsBeforeStaleWrite() async throws {
        let (server, client) = try await editingValidationServer(mismatchedReadback: true)
        let report = try await client.validateNoteEditing(notebookID: "book-1")
        #expect(report.stage == .updateRead)
        #expect(!report.updateConfirmed && !report.passed)
        #expect(report.failure != nil)
        server.assertConsumed()
    }

    @Test func testLostUpdateResponseKeepsTargetIDAndDoesNotRetryWrite() async throws {
        let (server, client) = try await editingValidationServer(failedUpdateResponse: true)
        let report = try await client.validateNoteEditing(notebookID: "book-1")
        #expect(report.receipt.objectID == "probe-1")
        #expect(report.stage == .update && report.failure != nil && !report.passed)
        server.assertConsumed()
    }

    @Test func testDisconnectBetweenValidationStepsNeverWritesToNewSession() async throws {
        let pause = ResponsePause()
        let (server, client) = try await editingValidationServer(pauseInitialRead: pause)
        let pending = Task { try await client.validateNoteEditing(notebookID: "book-1") }
        await pause.waitUntilStarted()
        await assertError(.validationInProgress) { try await client.validateNoteEditing(notebookID: "book-1") }
        await client.disconnect()
        await pause.resume()
        let report = try await pending.value
        #expect(report.stage == .initialRead && !report.passed)
        #expect(report.failure == NoteStationError.connectionChanged.localizedDescription)
        server.assertConsumed()
    }

    private func editingValidationServer(staleCode: Int? = 1064, mismatchedReadback: Bool = false,
                                         failedUpdateResponse: Bool = false, pauseInitialRead: ResponsePause? = nil,
                                         lostLatestContent: Bool = false, malformedSetReceipt: Bool = false) async throws -> (FakeNAS, NoteStationClient) {
        let server = FakeNAS(); server.login()
        let state = ValidationFixture()
        server.dynamicJSON { _, form in
            expectEqual(form["method"], "create")
            state.title = Self.decodedString(form["title"])
            state.original = Self.decodedString(form["content"])
            expectTrue(state.title.hasPrefix("[SynologyNote 검증] 수정·충돌 "))
            return #"{"success":true,"data":{"object_id":"probe-1","ver":"v1"}}"#
        }
        if let pauseInitialRead {
            server.bytes(Data(state.body(version: "v1", html: "unused").utf8), contentType: "application/json", pause: pauseInitialRead)
        } else {
            server.dynamicJSON { _, form in
                expectEqual(form["object_id"], #""probe-1""#)
                return state.body(version: "v1", html: state.original)
            }
            server.json(Self.noShortcuts)
            if failedUpdateResponse {
                server.json("response lost", status: 504) { _, form in
                    expectEqual(form["method"], "set")
                }
            } else if malformedSetReceipt {
                server.json(#"{"success":true,"data":{"data":[{"object_id":"wrong-note","ver":"v2"}]}}"#) { _, form in
                    Self.checkValidationSet(form, baseVersion: "v1")
                }
            } else {
                server.dynamicJSON { _, form in
                    Self.checkValidationSet(form, baseVersion: "v1")
                    state.updated = Self.decodedString(form["content"])
                    return #"{"success":true,"data":{"data":[{"object_id":"probe-1","ver":"v2"}]}}"#
                }
                server.dynamicJSON { _, _ in state.body(version: "v2", html: mismatchedReadback ? state.original : state.updated) }
                server.json(Self.noShortcuts)
                if !mismatchedReadback {
                    server.dynamicJSON { _, form in
                        Self.checkValidationSet(form, baseVersion: "v1")
                        state.stale = Self.decodedString(form["content"])
                        expectFalse(state.stale == state.updated)
                        if let staleCode { return "{\"success\":false,\"error\":{\"code\":\(staleCode)}}" }
                        return #"{"success":true,"data":{"data":[{"ver":"v3"}]}}"#
                    }
                    server.dynamicJSON { _, _ in state.body(version: staleCode == nil ? "v3" : "v2", html: staleCode == nil || lostLatestContent ? state.stale : state.updated) }
                    server.json(Self.noShortcuts)
                }
            }
        }
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        return (server, client)
    }

    private static let noShortcuts = #"{"success":true,"data":{"offset":0,"total":0,"shortcuts":[]}}"#

    private static func decodedString(_ value: String?) -> String {
        guard let value, let decoded = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) as? String else { return "" }
        return decoded
    }

    private static func checkValidationSet(_ form: [String: String], baseVersion: String) {
        expectEqual(form["api"], "SYNO.NoteStation.Note")
        expectEqual(form["method"], "set")
        expectEqual(form["version"], "3")
        expectEqual(decodedString(form["object_id"]), "probe-1")
        expectEqual(decodedString(form["ver"]), baseVersion)
        expectEqual(form["check_conflict"], "true")
        expectNil(form["attachment"])
        expectNil(form["recycle"])
        expectEqual(form["commit_msg"], #"{"device":"desktop","listable":false}"#)
    }

    @Test func testMalformedListDoesNotSilentlyBecomeEmptyOrAdvanceProgress() async throws {
        let server = FakeNAS(); server.login()
        server.json(#"{"success":true,"data":{"offset":0,"total":1,"notes":null}}"#)
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        await assertError(.invalidResponse) { try await client.notes() }
        server.assertConsumed()
    }

    @Test func testEmptyRealListWithNullIsAcceptedAndDisconnectIsLocal() async throws {
        let server = FakeNAS(); server.login()
        server.json(#"{"success":true,"data":{"offset":0,"total":0,"notebooks":null}}"#)
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        let books = try await client.notebooks(); expectTrue(books.isEmpty)
        await client.disconnect()
        await assertError(.notConnected) { try await client.notes() }
        server.assertConsumed()
    }

    @Test func testPermissionAndHTTPAndTransportErrorsKeepStructuredCodes() async throws {
        for (reply, expected) in [(105, NoteStationError.permissionDenied), (120, .api(code: 120))] {
            let server = FakeNAS(); server.login()
            server.json("{\"success\":false,\"error\":{\"code\":\(reply)}}")
            let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
            await assertError(expected) { try await client.notebooks() }
            server.assertConsumed()
        }
        let server = FakeNAS(); server.json("synthetic-private-body", status: 503)
        let client = server.client()
        await assertError(.http(status: 503)) { try await client.connect(username: "synthetic", password: "synthetic") }
        server.assertConsumed()
    }

    @Test func testDownloadJSONErrorIsNotReturnedAsFileData() async throws {
        let server = FakeNAS(); server.login()
        server.json(#"{"success":false,"error":{"code":119}}"#)
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        await assertError(.sessionExpired) { try await client.download(fileID: "file-1", noteID: "note-1") }
        server.assertConsumed()
    }

    @Test func testDiscoveryMissingAPIDoesNotGuessEntryPath() async throws {
        let server = FakeNAS(); server.json(#"{"success":true,"data":{}}"#)
        let client = server.client()
        await assertError(.unsupportedAPI("SYNO.API.Auth")) { try await client.connect(username: "synthetic", password: "synthetic") }
        server.assertConsumed()
    }

    @Test func testPartialDetailPreservesListNotebookTagsAndFlags() async throws {
        let server = FakeNAS(); server.login()
        server.json(#"{"success":true,"data":{"offset":0,"total":1,"notes":[{"object_id":"note-1","title":"一覧","parent_id":"book-1","ver":"v1","mtime":1700000000,"tag":["保留"],"encrypt":false,"recycle":true}]}}"#)
        server.json(#"{"success":true,"data":{"offset":0,"total":1,"shortcuts":[{"id":"note-1","category":"note"}]}}"#)
        server.json(#"{"success":true,"data":{"title":"本文","ver":"v2","mtime":1700000002,"content":"<p>synthetic</p>"}}"#)
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        _ = try await client.notes()
        let detail = try await client.fetch(noteID: "note-1")
        expectEqual(detail.summary.id, "note-1")
        expectEqual(detail.summary.notebookID, "book-1")
        expectEqual(detail.summary.tags, ["保留"])
        expectTrue(detail.summary.isTrashed); expectTrue(detail.summary.isFavorite)
        expectEqual(detail.summary.version, "v2")
        expectEqual(detail.summary.title, "本文")
        server.assertConsumed()
    }

    @Test func testIncompletePaginationDuplicateRowsAndChangedTotalAreErrors() async throws {
        let first = #"{"success":true,"data":{"offset":0,"total":2,"notebooks":[{"object_id":"b1","title":"synthetic"}]}}"#
        for second in [
            #"{"success":true,"data":{"offset":1,"total":2,"notebooks":[]}}"#,
            #"{"success":true,"data":{"offset":1,"total":2,"notebooks":[{"object_id":"b1","title":"duplicate"}]}}"#,
            #"{"success":true,"data":{"offset":1,"total":3,"notebooks":[{"object_id":"b2","title":"changed"}]}}"#,
            #"{"success":true,"data":{"offset":0,"total":2,"notebooks":[{"object_id":"b2","title":"wrong offset"}]}}"#
        ] {
            let server = FakeNAS(); server.login(); server.json(first); server.json(second)
            let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
            await assertError(.invalidResponse) { try await client.notebooks() }
            server.assertConsumed()
        }
    }

    @Test func testHistoryPaginationAndAdvertisedLegacyCGIUsesRawStrings() async throws {
        let server = FakeNAS()
        server.json(Self.authInfo); server.json(#"{"success":true,"data":{"sid":"synthetic-sid"}}"#)
        server.json(Self.apiInfo.replacingOccurrences(of: #""path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON""#,
                                                      with: #""path":"history.cgi","minVersion":1,"maxVersion":2"#))
        server.json(#"{"success":true,"data":{"offset":0,"total":2,"versions":[{"version":"v1","mtime":1}]}}"#) { req, form in
            expectEqual(req.url?.path, "/webapi/history.cgi")
            expectEqual(form["object_id"], "note/+&=한글")
            expectEqual(form["filter"], #"{"listable":true}"#)
        }
        server.json(#"{"success":true,"data":{"offset":1,"total":2,"versions":[{"version":"v2","mtime":2}]}}"#) { _, form in
            expectEqual(form["offset"], "1")
        }
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        let history = try await client.versionHistory(noteID: "note/+&=한글")
        expectEqual(history.map(\.version), ["v1", "v2"])
        server.assertConsumed()
    }

    @Test func testEncryptedBodyFailsClosedAndDoesNotReturnCiphertextAsHTML() async throws {
        let server = FakeNAS(); server.login()
        server.json(#"{"success":true,"data":{"object_id":"note-1","encrypt":true,"content":"synthetic-ciphertext"}}"#)
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        await assertError(.lockedNote) { try await client.fetch(noteID: "note-1") }
        expectTrue(client.capabilities.supportsReads)
        expectFalse(client.capabilities.supportsWrites)
        expectFalse(client.capabilities.supportsEncryptedNotes)
        server.assertConsumed()
    }

    @Test func testDiscoveryCannotRedirectCredentialsOutsideWebAPIRoot() async throws {
        for path in ["https://outside.invalid/auth.cgi", "../auth.cgi", "/auth.cgi", "%2e%2e/auth.cgi"] {
            let server = FakeNAS(); server.json(Self.authInfo.replacingOccurrences(of: "auth.cgi", with: path))
            let client = server.client()
            await assertError(.invalidResponse) { try await client.connect(username: "synthetic", password: "synthetic") }
            server.assertConsumed()
        }
    }

    @Test func testDisconnectDuringInflightRequestCannotRestoreOldConnection() async throws {
        let server = FakeNAS(); server.login()
        let pause = ResponsePause()
        server.bytes(Data(#"{"success":true,"data":{"offset":0,"total":0,"notebooks":[]}}"#.utf8), contentType: "application/json", pause: pause)
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        let pending = Task { try await client.notebooks() }
        await pause.waitUntilStarted()
        await client.disconnect()
        await pause.resume()
        await assertError(.connectionChanged) { try await pending.value }
        await assertError(.notConnected) { try await client.notes() }
        server.assertConsumed()
    }

    @Test func testValidJSONAttachmentIsReturnedWithoutEnvelopeGuessing() async throws {
        let server = FakeNAS(); server.login()
        let body = Data(#"{"synthetic":"file contents"}"#.utf8)
        server.bytes(body, contentType: "application/json")
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        let data = try await client.download(fileID: "json", noteID: "note-1")
        expectEqual(data, body)
        server.assertConsumed()
    }

    @Test func testKeychainRejectsEmptyAccountBeforeAccessingKeychain() throws {
        #expect(throws: CredentialStoreError.invalidAccount) { try CredentialStore.save(password: "synthetic", account: " ") }
        #expect(throws: CredentialStoreError.invalidAccount) { try CredentialStore.load(account: "") }
        #expect(throws: CredentialStoreError.invalidAccount) { try CredentialStore.remove(account: "") }
    }

    @Test func testKeychainRoundTripUpdateIsolationAndIdempotentRemoval() throws {
        let fixture = try TemporaryTestKeychain()
        defer { withExtendedLifetime(fixture) {} }
        let keychain = fixture.reference
        let account = "notestation-tests-\(UUID().uuidString)"
        let other = "notestation-tests-\(UUID().uuidString)"
        expectNil(try CredentialStore.load(account: account, testKeychain: keychain))
        try CredentialStore.save(password: "synthetic 한글🔐", account: account, testKeychain: keychain)
        try CredentialStore.save(password: "synthetic-other", account: other, testKeychain: keychain)
        expectEqual(try CredentialStore.load(account: account, testKeychain: keychain), "synthetic 한글🔐")
        try CredentialStore.save(password: "synthetic-updated", account: account, testKeychain: keychain)
        expectEqual(try CredentialStore.load(account: account, testKeychain: keychain), "synthetic-updated")
        expectEqual(try CredentialStore.load(account: other, testKeychain: keychain), "synthetic-other")
        try CredentialStore.remove(account: account, testKeychain: keychain)
        try CredentialStore.remove(account: account, testKeychain: keychain)
        expectNil(try CredentialStore.load(account: account, testKeychain: keychain))
    }

    private func assertError<T>(_ expected: NoteStationError, file: StaticString = #filePath, line: UInt = #line, _ operation: () async throws -> T) async {
        do { _ = try await operation(); recordFailure("Expected structured error", file: file, line: line) }
        catch { expectEqual(error as? NoteStationError, expected, file: file, line: line) }
    }

    fileprivate static let authInfo = #"{"success":true,"data":{"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":7}}}"#
    fileprivate static let apiInfo = #"{"success":true,"data":{"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":7},"SYNO.NoteStation.Notebook":{"path":"entry.cgi","minVersion":1,"maxVersion":99,"requestFormat":"JSON"},"SYNO.NoteStation.Note":{"path":"entry.cgi","minVersion":1,"maxVersion":3,"requestFormat":"JSON"},"SYNO.NoteStation.Shortcut":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"},"SYNO.NoteStation.Note.Version":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"}}}"#
    fileprivate static let note = #"{"success":true,"data":{"object_id":"note/+&=한글","title":"합성 문서","parent_id":"book-1","ver":"v4","mtime":1700000001,"tag":["태그"],"encrypt":false,"recycle":false,"content":"<p>합성 문서</p>","attachment":{"file-2":{"name":"synthetic.bin","size":4},"file-1":{"name":"synthetic.png","type":"image/png","size":100,"ref":"image-ref"}}}}"#
}

private final class ValidationFixture {
    var title = "", original = "", updated = "", stale = ""
    func body(version: String, html: String) -> String {
        let object: [String: Any] = ["success": true, "data": [
            "object_id": "probe-1", "title": title, "parent_id": "book-1", "ver": version,
            "mtime": 1700000000, "tag": [], "encrypt": false, "recycle": false,
            "content": html, "attachment": [:]
        ] as [String: Any]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

private final class FakeNAS: @unchecked Sendable {
    typealias Check = (URLRequest, [String: String]) -> Void
    struct Reply { let data: Data; let status: Int; let contentType: String; let check: Check; let pause: ResponsePause?; let response: ((URLRequest, [String: String]) -> Data)? }
    let host = "nas-\(UUID().uuidString.lowercased()).invalid"
    let session: URLSession
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var unexpected = 0
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NASURLProtocol.self]
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
        NASURLProtocol.register(self)
    }
    deinit { NASURLProtocol.unregister(host); session.invalidateAndCancel() }
    func client(prefix: String = "") -> NoteStationClient {
        NoteStationClient(baseURL: URL(string: "https://\(host)\(prefix)")!, session: session)
    }
    func json(_ text: String, status: Int = 200, check: @escaping Check = { _, _ in }) {
        bytes(Data(text.utf8), status: status, contentType: "application/json", check: check)
    }
    func bytes(_ data: Data, status: Int = 200, contentType: String, pause: ResponsePause? = nil, check: @escaping Check = { _, _ in }) {
        lock.lock(); defer { lock.unlock() }
        replies.append(Reply(data: data, status: status, contentType: contentType, check: check, pause: pause, response: nil))
    }
    func dynamicJSON(_ response: @escaping (URLRequest, [String: String]) -> String) {
        dynamicBytes(contentType: "application/json") { request, form in Data(response(request, form).utf8) }
    }
    func dynamicBytes(contentType: String, response: @escaping (URLRequest, [String: String]) -> Data) {
        lock.lock(); defer { lock.unlock() }
        replies.append(Reply(data: Data(), status: 200, contentType: contentType, check: { _, _ in }, pause: nil, response: response))
    }
    func login() {
        json(NoteStationTests.authInfo)
        json(#"{"success":true,"data":{"sid":"synthetic-sid"}}"#)
        json(NoteStationTests.apiInfo)
    }
    func next() -> Reply? {
        lock.lock(); defer { lock.unlock() }
        guard !replies.isEmpty else { unexpected += 1; return nil }
        return replies.removeFirst()
    }
    func assertConsumed(file: StaticString = #filePath, line: UInt = #line) {
        lock.lock(); defer { lock.unlock() }
        expectEqual(replies.count, 0, "Missing expected requests", file: file, line: line)
        expectEqual(unexpected, 0, "Unexpected network request", file: file, line: line)
    }
}

private final class NASURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var servers: [String: WeakServer] = [:]
    private final class WeakServer { weak var value: FakeNAS?; init(_ value: FakeNAS) { self.value = value } }
    static func register(_ server: FakeNAS) { lock.lock(); defer { lock.unlock() }; servers[server.host] = WeakServer(server) }
    static func unregister(_ host: String) { lock.lock(); defer { lock.unlock() }; servers.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let server = Self.servers[request.url?.host ?? ""]?.value; Self.lock.unlock()
        guard let reply = server?.next(), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        var form = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                form[String(parts[0]).removingPercentEncoding ?? ""] = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            }
        }
        var captured = request
        captured.httpBody = data
        if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true {
            form.merge(Dictionary(uniqueKeysWithValues: multipartTestParts(captured).filter { $0.filename == nil }.map { ($0.name, String(decoding: $0.data, as: UTF8.self)) })) { _, new in new }
        }
        reply.check(captured, form)
        let responseBytes = reply.response?(captured, form) ?? reply.data
        Task {
            if let pause = reply.pause { await pause.wait() }
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBytes)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private actor ResponsePause {
    private var started = false
    private var onStart: CheckedContinuation<Void, Never>?
    private var onResume: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            onResume = continuation
            started = true
            onStart?.resume(); onStart = nil
        }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { onStart = $0 } }
    }
    func resume() { onResume?.resume(); onResume = nil }
}

private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    #expect(lhs == rhs, Comment(rawValue: message))
}
private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { #expect(value == nil) }
private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { #expect(value) }
private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { #expect(!value) }
private func recordFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line) { Issue.record(Comment(rawValue: message)) }


extension NoteStationTests {
    @Test func testImageAndMarkdownAttachmentRoundTripUsesMatchingBinaryParts() async throws {
        let (server, client) = try await attachmentValidationServer()
        let report = try await client.validateNoteAttachments(notebookID: "book-1")
        #expect(report.passed)
        #expect(report.imageBytesVerified && report.sourceBytesVerified && report.markdownRestored)
        #expect(!client.capabilities.supportsWrites)
        server.assertConsumed()
    }

    @Test func testCorruptImageStopsBeforeSourceUploadWithoutRetry() async throws {
        let (server, client) = try await attachmentValidationServer(corruptImage: true)
        let report = try await client.validateNoteAttachments(notebookID: "book-1")
        #expect(!report.passed && !report.imageBytesVerified)
        #expect(report.stage == .imageRead && report.failure != nil)
        server.assertConsumed()
    }

    @Test func testCorruptSourceCannotReportSuccessfulMarkdownRestore() async throws {
        let (server, client) = try await attachmentValidationServer(corruptSource: true)
        let report = try await client.validateNoteAttachments(notebookID: "book-1")
        #expect(!report.passed && !report.sourceBytesVerified && !report.markdownRestored)
        #expect(report.stage == .finalRead && report.failure != nil)
        server.assertConsumed()
    }

    private func attachmentValidationServer(corruptImage: Bool = false, corruptSource: Bool = false) async throws -> (FakeNAS, NoteStationClient) {
        let server = FakeNAS(); server.login()
        let fixture = AttachmentProbeFixture()
        server.dynamicJSON { _, form in
            expectEqual(form["method"], "create")
            fixture.title = Self.decodedString(form["title"])
            fixture.html = Self.decodedString(form["content"])
            expectTrue(fixture.title.hasPrefix("[SynologyNote 검증] 첨부·Markdown "))
            return #"{"success":true,"data":{"object_id":"attachment-probe","ver":"v1"}}"#
        }
        server.dynamicJSON { _, _ in fixture.body(version: "v1") }
        server.json(Self.noShortcuts)
        server.dynamicJSON { request, form in
            fixture.capture(request, form: form, image: true)
            return #"{"success":true,"data":{"data":[{"object_id":"attachment-probe","ver":"v2"}]}}"#
        }
        server.dynamicJSON { _, _ in fixture.body(version: "v2") }
        server.json(Self.noShortcuts)
        server.dynamicBytes(contentType: "image/png") { _, form in
            expectEqual(Self.decodedString(form["file_id"]), "image-file")
            expectEqual(Self.decodedString(form["mode"]), "download")
            return corruptImage ? Data([0]) : fixture.imageBytes
        }
        if !corruptImage {
            server.dynamicJSON { request, form in
                fixture.capture(request, form: form, image: false)
                return #"{"success":true,"data":{"data":[{"object_id":"attachment-probe","ver":"v3"}]}}"#
            }
            server.dynamicJSON { _, _ in fixture.body(version: "v3") }
            server.json(Self.noShortcuts)
            server.dynamicBytes(contentType: "text/markdown") { _, form in
                expectEqual(Self.decodedString(form["file_id"]), "source-file")
                return corruptSource ? Data("corrupt".utf8) : fixture.sourceBytes
            }
            if !corruptSource {
                server.dynamicBytes(contentType: "image/png") { _, form in
                    expectEqual(Self.decodedString(form["file_id"]), "image-file")
                    return fixture.imageBytes
                }
            }
        }
        let client = server.client(); try await client.connect(username: "synthetic", password: "synthetic")
        return (server, client)
    }
}

private final class AttachmentProbeFixture {
    var title = "", html = "", imageRef = "", imageName = "", sourceName = ""
    var imageBytes = Data(), sourceBytes = Data()
    func capture(_ request: URLRequest, form: [String: String], image: Bool) {
        let routing = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(routing.first(where: { $0.name == "api" })?.value == "SYNO.NoteStation.Note")
        #expect(routing.first(where: { $0.name == "method" })?.value == "set")
        #expect(routing.first(where: { $0.name == "version" })?.value == "3")
        #expect(routing.first(where: { $0.name == "_sid" })?.value == "synthetic-sid")
        #expect(!multipartTestParts(request).contains(where: { ["api", "method", "version", "_sid"].contains($0.name) }))
        #expect(form["method"] == "set")
        #expect(form["version"] == "3")
        #expect(form["object_id"] == #""attachment-probe""#)
        #expect(form["ver"] == (image ? #""v1""# : #""v2""#))
        #expect(form["check_conflict"] == "true")
        guard let encoded = form["attachment"],
              let entries = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]],
              entries.count == 1, let partName = entries[0]["name"] as? String,
              let part = multipartTestParts(request).first(where: { $0.name == partName && $0.filename != nil }) else {
            Issue.record("Missing binary referenced by attachment metadata"); return
        }
        #expect(entries[0]["action"] as? String == "create")
        #expect(entries[0]["format"] as? String == "raw")
        #expect(entries[0]["rotate"] as? Bool == false)
        #expect(entries[0]["convert"] as? Bool == false)
        #expect(part.data.count > 0)
        guard let content = form["content"], let decoded = try? JSONSerialization.jsonObject(with: Data(content.utf8), options: .fragmentsAllowed) as? String else {
            Issue.record("Missing HTML"); return
        }
        if image {
            imageBytes = part.data; imageName = part.filename ?? ""
            imageRef = entries[0]["ref"] as? String ?? ""
            #expect(UUID(uuidString: imageRef) != nil)
            #expect(decoded.contains(imageRef))
            html = decoded
        } else {
            #expect(decoded == html)
            #expect(entries[0]["ref"] == nil)
            sourceBytes = part.data; sourceName = part.filename ?? ""
            guard let envelope = try? SourceEnvelope.decode(sourceBytes) else { Issue.record("Invalid source envelope"); return }
            #expect(envelope.matches(html: html))
            #expect(envelope.markdown.contains("attachment://" + imageRef))
        }
    }
    func body(version: String) -> String {
        var files: [String: Any] = [:]
        if !imageName.isEmpty { files["image-file"] = ["name": imageName, "type": "image/png", "ref": imageRef] }
        if !sourceName.isEmpty { files["source-file"] = ["name": sourceName, "type": "text/markdown"] }
        let object: [String: Any] = ["success": true, "data": [
            "object_id": "attachment-probe", "title": title, "parent_id": "book-1", "ver": version,
            "mtime": 1700000000, "tag": [], "encrypt": false, "recycle": false, "content": html, "attachment": files
        ] as [String: Any]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

struct MultipartTestPart { let name: String; let filename: String?; let data: Data }
func multipartTestParts(_ request: URLRequest) -> [MultipartTestPart] {
    guard let type = request.value(forHTTPHeaderField: "Content-Type"),
          let boundaryRange = type.range(of: "boundary="), let body = request.httpBody else { return [] }
    let boundary = String(type[boundaryRange.upperBound...])
    let marker = Data(("--" + boundary).utf8)
    let headerSeparator = Data("\r\n\r\n".utf8)
    var cursor = body.startIndex
    var parts: [MultipartTestPart] = []
    while let first = body.range(of: marker, in: cursor..<body.endIndex) {
        let start = first.upperBound + 2
        guard start < body.endIndex, let next = body.range(of: marker, in: start..<body.endIndex),
              let separator = body.range(of: headerSeparator, in: start..<next.lowerBound) else { break }
        let headers = String(decoding: body[start..<separator.lowerBound], as: UTF8.self)
        func attribute(_ name: String) -> String? {
            guard let range = headers.range(of: name + "=\"") else { return nil }
            let tail = headers[range.upperBound...]
            guard let end = tail.firstIndex(of: "\"") else { return nil }
            return String(tail[..<end])
        }
        if let name = attribute("name") {
            parts.append(MultipartTestPart(name: name, filename: attribute("filename"), data: Data(body[separator.upperBound..<(next.lowerBound - 2)])))
        }
        cursor = next.lowerBound
    }
    return parts
}
