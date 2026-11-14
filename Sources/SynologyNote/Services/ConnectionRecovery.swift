import AppKit
import Foundation
import Network
import NoteCore

enum ConnectionRetrySchedule {
    static let maximumDuration: Duration = .seconds(30 * 60)

    static func delay(_ attempt: Int) -> Duration {
        let step = max(0, attempt) % 7
        return .seconds(min(120, 2 * (1 << step)))
    }
}

extension LibraryStore {
    static func isRecoverableConnectionError(_ error: Error) -> Bool {
        guard let error = error as? NoteStationError else { return false }
        switch error {
        case .sessionExpired, .notConnected: return true
        case .transport(let code): return [-1001, -1003, -1004, -1005, -1006, -1009, -1018, -1020].contains(code)
        case .http(let status): return status == 408 || status == 429 || status >= 500
        default: return false
        }
    }

    func stopConnectionRecovery(resetWindow: Bool = true) {
        recoveryID = nil; recoveryTask?.cancel(); recoveryTask = nil
        if resetWindow { recoveryStartedAt = nil; recoveryExpired = false }
    }

    func requestConnectionRecovery(after error: Error, immediate: Bool = false) {
        lastConnectionFailure = error
        guard Self.isRecoverableConnectionError(error) else { return }
        guard !recoveryExpired else { return }
        logEvent(.recoveryStarted, error: error)
        isConnected = false
        cancelOfflineDownload()
        connectionError = error.localizedDescription
        connectionStatus = "오프라인 · 연결 복구 대기"
        guard recoveryAllowed, !recoveryBlocked, profile.autoConnect, profile.rememberPassword,
              !profile.server.isEmpty, !profile.username.isEmpty, recoveryTask == nil else { return }
        let id = UUID(), savedProfile = profile, account = accountGeneration
        let clock = ContinuousClock()
        let started = recoveryStartedAt ?? clock.now
        recoveryStartedAt = started
        recoveryID = id
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.recoveryID == id { self.recoveryTask = nil; self.recoveryID = nil } }
            var attempt = 0
            while !Task.isCancelled, self.recoveryID == id, self.recoveryAllowed,
                  self.profile.autoConnect, self.profile.rememberPassword,
                  self.profile.storageKey == savedProfile.storageKey, self.accountGeneration == account {
                let remaining = clock.now.duration(to: started.advanced(by: self.recoveryWindow))
                guard remaining > .zero else {
                    self.recoveryExpired = true
                    self.connectionStatus = "자동 재연결 종료 · 30분 경과"
                    return
                }
                let delay = immediate && attempt == 0 ? Duration.zero : self.recoveryDelay(attempt)
                do { try await Task.sleep(for: min(delay, remaining)) }
                catch { return }
                guard !Task.isCancelled, self.recoveryID == id else { return }
                guard clock.now < started.advanced(by: self.recoveryWindow) else {
                    self.recoveryExpired = true
                    self.connectionStatus = "자동 재연결 종료 · 30분 경과"
                    return
                }
                if self.isPushing || self.isRefreshing { attempt += 1; continue }
                let generation = self.connectionGeneration
                self.connectionStatus = "저장된 계정으로 재연결 중…"
                let credentials: SavedNASCredentials?
                do { credentials = try await self.credentialAccess.load(savedProfile.storageKey) }
                catch {
                    guard self.recoveryID == id else { return }
                    self.recoveryBlocked = true
                    self.reportCredentialAccessFailure(error)
                    return
                }
                guard self.recoveryID == id, generation == self.connectionGeneration,
                      self.accountGeneration == account, !Task.isCancelled else { return }
                guard let password = credentials?.password, !password.isEmpty else {
                    self.recoveryBlocked = true; self.connectionStatus = "로그인 필요"
                    self.loginStorageMessage = "저장된 비밀번호가 없습니다. 설정에서 로그인하세요."
                    return
                }
                await self.connect(profile: self.profile, password: password, automatic: true, storedCredentials: credentials)
                guard self.recoveryID == id, !Task.isCancelled else { return }
                if self.isConnected { return }
                guard let failure = self.lastConnectionFailure, Self.isRecoverableConnectionError(failure) else {
                    self.recoveryBlocked = true
                    return
                }
                self.connectionStatus = "오프라인 · 연결 복구 대기"
                attempt += 1
            }
        }
    }

    func connectionBecameAvailable() {
        guard attemptedStartupConnection, recoveryAllowed, !recoveryBlocked else { return }
        if isConnected {
            Task { [weak self] in await self?.refreshFromServer() }
        } else {
            guard profile.autoConnect, profile.rememberPassword, !isRefreshing, !isPushing else { return }
            stopConnectionRecovery(resetWindow: false)
            requestConnectionRecovery(after: NoteStationError.notConnected, immediate: true)
        }
    }
}

@MainActor final class ConnectionEvents {
    private let monitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    init(store: LibraryStore) {
        monitor.pathUpdateHandler = { [weak store] path in
            if path.status == .satisfied { Task { @MainActor in store?.connectionBecameAvailable() } }
        }
        monitor.start(queue: DispatchQueue(label: "SynologyNote.network"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak store] _ in
            Task { @MainActor in store?.connectionBecameAvailable() }
        }
    }
    deinit {
        monitor.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
