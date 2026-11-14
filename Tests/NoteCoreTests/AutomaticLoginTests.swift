import Foundation
import Testing
import NoteCore
@testable import SynologyNote

@Suite @MainActor struct AutomaticLoginTests {
    @Test func recoveryWaitsCycleBackToSecondsAfterTwoMinutes() {
        let delays = (0...8).map(ConnectionRetrySchedule.delay)
        #expect(delays == [.seconds(2), .seconds(4), .seconds(8), .seconds(16),
                           .seconds(32), .seconds(64), .seconds(120), .seconds(2), .seconds(4)])
        #expect(ConnectionRetrySchedule.maximumDuration == .seconds(1800))
    }

    @Test func exhaustedRecoveryWindowStopsAutomaticAttemptsEvenAfterNetworkWake() async throws {
        let fixture = try Fixture(saved: SavedNASCredentials(password: "saved"))
        defer { fixture.cleanup() }
        fixture.store.recoveryWindow = .zero
        fixture.store.attemptedStartupConnection = true
        fixture.store.requestConnectionRecovery(after: NoteStationError.notConnected)
        let scheduled = fixture.store.recoveryTask
        #expect(scheduled != nil)
        await scheduled?.value
        #expect(fixture.store.recoveryExpired)
        #expect(fixture.store.connectionStatus.contains("30분"))
        fixture.store.connectionBecameAvailable()
        #expect(fixture.store.recoveryTask == nil)
        #expect(fixture.server.logins().isEmpty)
    }

    @Test func manualLoginAfterRecoveryTimeoutResetsRetryWindow() async throws {
        let fixture = try Fixture(saved: SavedNASCredentials(password: "saved"))
        defer { fixture.cleanup() }
        fixture.store.recoveryWindow = .zero
        fixture.store.requestConnectionRecovery(after: NoteStationError.notConnected)
        await fixture.store.recoveryTask?.value
        #expect(fixture.store.recoveryExpired)

        await fixture.store.connect(profile: fixture.store.profile, password: "saved")
        #expect(fixture.store.isConnected)
        #expect(!fixture.store.recoveryExpired)
        #expect(fixture.store.recoveryStartedAt == nil)
        #expect(fixture.server.logins().count == 1)
    }

    @Test func existingProfileMigratesWithAutoConnectAndDeviceTrust() throws {
        let data = Data(#"{"server":"https://example.invalid","username":"user","rememberPassword":true}"#.utf8)
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        #expect(profile.autoConnect && profile.rememberDevice)
        let encoded = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        #expect(!encoded.contains("deviceID") && !encoded.contains("otp_code"))
    }

    @Test func startupLogsInOnceUsingSavedDeviceAndPassword() async throws {
        let fixture = try Fixture(saved: SavedNASCredentials(password: "saved-password", deviceID: "remembered-device"))
        defer { fixture.cleanup() }
        await fixture.store.restoreConnectionIfNeeded()
        await fixture.store.restoreConnectionIfNeeded()
        #expect(fixture.store.isConnected)
        #expect(fixture.store.trustedDeviceRemembered)
        let logins = fixture.server.logins()
        #expect(logins.count == 1)
        #expect(logins.first?["device_id"] == "remembered-device")
        #expect(logins.first?["otp_code"] == nil)
        #expect(await fixture.vault.saveCount == 0)
    }

    @Test func disabledAutoLoginAndMissingPasswordNeverAttemptAuthentication() async throws {
        for disabled in [true, false] {
            let fixture = try Fixture(saved: disabled ? SavedNASCredentials(password: "saved") : nil, autoConnect: !disabled)
            defer { fixture.cleanup() }
            await fixture.store.restoreConnectionIfNeeded()
            #expect(fixture.server.logins().isEmpty)
            #expect(!fixture.store.isConnected)
        }
    }

    @Test func blockedKeychainStartupExplainsPermissionWithoutRequestingAnotherNASLogin() async throws {
        let fixture = try Fixture(saved: SavedNASCredentials(password: "saved", deviceID: "remembered-device"))
        defer { fixture.cleanup() }
        fixture.store.credentialAccess.load = { _ in throw CredentialStoreError.keychain(status: -25308) }
        await fixture.store.restoreConnectionIfNeeded()
        #expect(fixture.store.connectionStatus == "키체인 접근 확인 필요")
        #expect(fixture.store.loginStorageMessage?.contains("항상 허용") == true)
        #expect(fixture.server.logins().isEmpty)
    }

    @Test func expiredSessionAutomaticallyReconnectsOnceWithDeviceToken() async throws {
        let fixture = try Fixture(saved: SavedNASCredentials(password: "saved", deviceID: "remembered-device"))
        defer { fixture.cleanup(); fixture.store.recoveryTask?.cancel(); fixture.store.offlineTask?.cancel() }
        fixture.store.recoveryDelay = { _ in .zero }
        await fixture.store.restoreConnectionIfNeeded()
        // A running upload can schedule its successor in its defer. Stop and
        // drain the loops first, then drain every replacement upload task so
        // refresh's idle-state guard cannot skip the expiry request under load.
        let refreshLoop = fixture.store.refreshTask
        let uploadLoop = fixture.store.uploadLoop
        refreshLoop?.cancel(); uploadLoop?.cancel()
        await refreshLoop?.value; await uploadLoop?.value
        while let scheduledUpload = fixture.store.uploadTask {
            fixture.store.uploadTask = nil
            scheduledUpload.cancel()
            await scheduledUpload.value
        }
        #expect(!fixture.store.isPushing && !fixture.store.isRefreshing)
        fixture.server.expireNextNoteList()
        await fixture.store.refreshFromServer()
        await fixture.store.recoveryTask?.value
        #expect(fixture.store.isConnected)
        #expect(fixture.server.logins().count == 2)
        #expect(fixture.server.logins().last?["device_id"] == "remembered-device")
        #expect(fixture.server.logins().last?["otp_code"] == nil)
    }

    @Test func manualDisconnectCancelsScheduledRecoveryAndWakeDoesNotReconnect() async throws {
        let fixture = try Fixture(saved: SavedNASCredentials(password: "saved"))
        defer { fixture.cleanup() }
        await fixture.store.restoreConnectionIfNeeded()
        fixture.store.recoveryDelay = { _ in .seconds(60) }
        fixture.store.requestConnectionRecovery(after: NoteStationError.transport(code: -1009))
        #expect(fixture.store.recoveryTask != nil)
        await fixture.store.disconnect()
        fixture.store.connectionBecameAvailable()
        #expect(fixture.store.recoveryTask == nil)
        #expect(fixture.server.logins().count == 1)
        #expect(!fixture.store.isConnected)
    }

    @Test func revokedDeviceStopsAtOTPChallengeWithoutRetryLoop() async throws {
        let fixture = try Fixture(saved: SavedNASCredentials(password: "saved", deviceID: "remembered-device"), otpRequired: true)
        defer { fixture.cleanup() }
        await fixture.store.restoreConnectionIfNeeded()
        await fixture.store.restoreConnectionIfNeeded()
        fixture.store.connectionBecameAvailable()
        #expect(!fixture.store.isConnected)
        #expect(fixture.store.connectionError == NoteStationError.otpRequired.localizedDescription)
        #expect(fixture.server.logins().count == 1)
        #expect(fixture.store.recoveryTask == nil)
    }

    @Test func manualOTPLoginStoresTokenAndNextLaunchUsesIt() async throws {
        let fixture = try Fixture(saved: nil)
        defer { fixture.cleanup() }
        await fixture.store.connect(profile: fixture.store.profile, password: "saved-password", otp: "123456")
        #expect(fixture.store.isConnected)
        let credentials = try await fixture.vault.load(fixture.store.profile.storageKey)
        #expect(credentials?.deviceID == "remembered-device")
        #expect(credentials?.password == "saved-password")
        #expect(await fixture.vault.saveCount == 1)
        await fixture.store.disconnect()
        let restarted = try LibraryStore(root: fixture.root, profile: fixture.store.profile, preferences: fixture.preferences)
        restarted.credentialAccess = fixture.vault.access
        restarted.clientFactory = { url, allowed in NoteStationClient(baseURL: url, session: fixture.server.session, allowsValidatedWrites: allowed) }
        defer { restarted.refreshTask?.cancel(); restarted.uploadLoop?.cancel(); restarted.uploadTask?.cancel(); restarted.offlineTask?.cancel() }
        await restarted.restoreConnectionIfNeeded()
        #expect(restarted.isConnected)
        #expect(fixture.server.logins().last?["device_id"] == "remembered-device")
        #expect(fixture.server.logins().last?["otp_code"] == nil)
    }

    @Test func manualDisconnectPreventsWindowStartupFromReconnecting() async throws {
        let fixture = try Fixture(saved: SavedNASCredentials(password: "saved"))
        defer { fixture.cleanup() }
        await fixture.store.disconnect()
        await fixture.store.restoreConnectionIfNeeded()
        #expect(fixture.server.logins().isEmpty)
    }

    @Test func keychainSaveFailureDoesNotInvalidateSuccessfulLoginOrClaimDeviceWasRemembered() async throws {
        let fixture = try Fixture(saved: nil)
        defer { fixture.cleanup() }
        fixture.store.credentialAccess.save = { _, _, _ in throw CredentialStoreError.keychain(status: -25308) }
        await fixture.store.connect(profile: fixture.store.profile, password: "test-password", otp: "123456")
        #expect(fixture.store.isConnected)
        #expect(!fixture.store.trustedDeviceRemembered)
        #expect(fixture.store.loginStorageMessage?.contains("저장하지 못했습니다") == true)
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let server: AutoLoginServer
        let vault: MemoryCredentialVault
        let store: LibraryStore
        init(saved: SavedNASCredentials?, autoConnect: Bool = true, otpRequired: Bool = false) throws {
            server = AutoLoginServer(otpRequired: otpRequired)
            let profile = ConnectionProfile(server: "https://\(server.host)", username: "test-user", autoConnect: autoConnect)
            vault = MemoryCredentialVault(key: profile.storageKey, credentials: saved)
            store = try LibraryStore(root: root, profile: profile, preferences: preferences)
            store.credentialAccess = vault.access
            let session = server.session
            store.clientFactory = { url, allowed in NoteStationClient(baseURL: url, session: session, allowsValidatedWrites: allowed) }
        }
        func cleanup() {
            store.refreshTask?.cancel(); store.uploadLoop?.cancel(); store.uploadTask?.cancel(); store.offlineTask?.cancel()
            server.close(); try? FileManager.default.removeItem(at: root)
        }
    }
}

private actor MemoryCredentialVault {
    private var values: [String: SavedNASCredentials] = [:]
    private(set) var saveCount = 0
    init(key: String, credentials: SavedNASCredentials?) { values[key] = credentials }
    func load(_ key: String) throws -> SavedNASCredentials? { values[key] }
    func save(_ credentials: SavedNASCredentials, key: String) { values[key] = credentials; saveCount += 1 }
    nonisolated var access: NASCredentialAccess {
        NASCredentialAccess(load: { try await self.load($0) }, save: { credentials, key, _ in await self.save(credentials, key: key) })
    }
}

private final class AutoLoginServer: @unchecked Sendable {
    let host = "login-\(UUID().uuidString.lowercased()).invalid"
    let session: URLSession
    let otpRequired: Bool
    private let lock = NSLock()
    private var attempts: [[String: String]] = []
    private var expiredNoteLists = 0
    func expireNextNoteList() { lock.lock(); expiredNoteLists += 1; lock.unlock() }
    init(otpRequired: Bool) {
        self.otpRequired = otpRequired
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutoLoginURLProtocol.self]
        session = URLSession(configuration: configuration)
        AutoLoginURLProtocol.register(self)
    }
    deinit { AutoLoginURLProtocol.unregister(host) }
    func close() { AutoLoginURLProtocol.unregister(host); session.invalidateAndCancel() }
    func logins() -> [[String: String]] { lock.lock(); defer { lock.unlock() }; return attempts }
    func reply(_ form: [String: String]) -> String {
        if form["method"] == "login" {
            lock.lock(); attempts.append(form); lock.unlock()
            if otpRequired { return #"{"success":false,"error":{"code":403}}"# }
            return #"{"success":true,"data":{"sid":"test-session","did":"remembered-device"}}"#
        }
        if form["method"] == "query" {
            return #"{"success":true,"data":{"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":7},"SYNO.NoteStation.Note":{"path":"entry.cgi","minVersion":1,"maxVersion":3,"requestFormat":"JSON"},"SYNO.NoteStation.Notebook":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"},"SYNO.NoteStation.Shortcut":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"}}}"#
        }
        if form["method"] == "list" {
            if form["api"] == "SYNO.NoteStation.Note" {
                lock.lock()
                let expired = expiredNoteLists > 0
                if expired { expiredNoteLists -= 1 }
                lock.unlock()
                if expired { return #"{"success":false,"error":{"code":119}}"# }
            }
            let key = form["api"] == "SYNO.NoteStation.Notebook" ? "notebooks" : form["api"] == "SYNO.NoteStation.Shortcut" ? "shortcuts" : "notes"
            return "{\"success\":true,\"data\":{\"offset\":0,\"total\":0,\"\(key)\":[]}}"
        }
        Issue.record("Unexpected automatic login request")
        return #"{"success":false,"error":{"code":120}}"#
    }
}

private final class AutoLoginURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var servers: [String: AutoLoginServer] = [:]
    static func register(_ server: AutoLoginServer) { lock.lock(); defer { lock.unlock() }; servers[server.host] = server }
    static func unregister(_ host: String) { lock.lock(); defer { lock.unlock() }; servers.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let server = Self.servers[request.url?.host ?? ""]; Self.lock.unlock()
        guard let server, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; bytes.append(buffer, count: size) }
        }
        var form: [String: String] = [:]
        for field in String(decoding: bytes, as: UTF8.self).split(separator: "&") {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { form[String(pair[0]).removingPercentEncoding ?? ""] = String(pair[1]).removingPercentEncoding }
        }
        let body = Data(server.reply(form).utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
