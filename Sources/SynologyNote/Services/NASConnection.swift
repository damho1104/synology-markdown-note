import Foundation
import NoteCore

enum LoginStorageIssue {
    case missingPassword, couldNotSave
}

extension LibraryStore {
    struct NASWriteValidationResult {
        let receipt: WriteValidationReceipt
        let confirmedInList: Bool
    }

    func restoreConnectionIfNeeded() async {
        guard !attemptedStartupConnection else { return }
        attemptedStartupConnection = true
        let savedProfile = profile, generation = connectionGeneration
        guard savedProfile.autoConnect, savedProfile.rememberPassword,
              !savedProfile.server.isEmpty, !savedProfile.username.isEmpty,
              !isConnected, !isRefreshing else { return }
        connectionStatus = appText("Checking Saved Account…")
        do {
            let credentials = try await credentialAccess.load(savedProfile.storageKey)
            guard generation == connectionGeneration, profile == savedProfile, !isConnected, !isRefreshing else { return }
            guard let password = credentials?.password, !password.isEmpty else {
                recoveryBlocked = true
                connectionStatus = appText("Sign-in Required")
                loginStorageIssue = .missingPassword
                loginStorageMessage = appText("No saved password. Sign in once from Settings.")
                return
            }
            await connect(profile: savedProfile, password: password, automatic: true, storedCredentials: credentials)
        } catch {
            guard generation == connectionGeneration else { return }
            reportCredentialAccessFailure(error)
        }
    }

    func connectUsingSavedAccount() async {
        guard !isRefreshing, !isPushing else { return }
        let savedProfile = profile, generation = connectionGeneration
        isRefreshing = true; connectionStatus = appText("Checking Sign-in Details in Keychain…"); loginStorageMessage = nil; connectionError = nil
        loginStorageIssue = nil
        do {
            let loader = credentialAccess.loadInteractive ?? credentialAccess.load
            let credentials = try await loader(savedProfile.storageKey)
            guard generation == connectionGeneration else { return }
            isRefreshing = false
            guard let password = credentials?.password, !password.isEmpty else {
                connectionStatus = appText("Sign-in Required")
                loginStorageIssue = .missingPassword
                loginStorageMessage = appText("No saved password. Enter it using “Edit Account Details…”.")
                return
            }
            await connect(profile: savedProfile, password: password, storedCredentials: credentials)
        } catch {
            guard generation == connectionGeneration else { return }
            isRefreshing = false; reportCredentialAccessFailure(error)
        }
    }

    func reportCredentialAccessFailure(_ error: Error) {
        recoveryBlocked = true
        if case CredentialStoreError.keychain = error {
            connectionStatus = appText("Keychain Access Required")
            loginStorageMessage = appText("Click “Reconnect” and choose Always Allow for SynologyCredentialHelper in the macOS Keychain prompt. This step does not require a NAS verification code.")
        } else {
            connectionStatus = appText("Sign-in Required")
            loginStorageMessage = appText("Could not read saved sign-in details. Check Settings.")
        }
    }

    func connect(profile newProfile: ConnectionProfile, password: String, otp: String? = nil,
                 automatic: Bool = false, storedCredentials: SavedNASCredentials? = nil) async {
        guard !isRefreshing else { return }
        let previousClient = client
        let previousProfile = profile
        let wasConnected = isConnected
        if !automatic { stopConnectionRecovery(); recoveryAllowed = true; recoveryBlocked = false }
        cancelOfflineDownload()
        lastConnectionFailure = nil
        connectionGeneration += 1
        let generation = connectionGeneration
        isRefreshing = true; connectionError = nil; connectionStatus = appText("Connecting…")
        logEvent(.connectionStarted, fields: ["automatic": String(automatic)])
        loginStorageIssue = nil
        loginStorageMessage = nil
        defer { if generation == connectionGeneration { isRefreshing = false } }
        do {
            guard let url = URL(string: newProfile.server.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else { throw NoteStationError.invalidBaseURL }
            let prior: SavedNASCredentials?
            if let storedCredentials { prior = storedCredentials }
            else if let otp, !otp.isEmpty { prior = nil }
            else { prior = try? await credentialAccess.load(newProfile.storageKey) }
            guard generation == connectionGeneration else { return }
            let client = clientFactory(url, true)
            try await client.connect(username: newProfile.username, password: password, otp: otp,
                                     rememberDevice: newProfile.rememberDevice, deviceID: prior?.deviceID)
            guard generation == connectionGeneration else { await client.disconnect(); return }
            await flush()
            guard generation == connectionGeneration else { await client.disconnect(); return }
            if sessions.values.contains(where: { $0.saveError != nil }) { throw RepositoryError(message: appText("Could not save the previous workspace. Check the save errors first.")) }
            if newProfile.storageKey != profile.storageKey {
                let directory = root.appendingPathComponent(newProfile.storageKey)
                let log = diagnosticLog ?? DiagnosticLog(root: root, policy: diagnosticLogPolicy)
                diagnosticLog = log
                let repo = try NoteRepository(directory: directory, diagnostics: log.maintenanceObserver(account: newProfile.storageKey))
                let assets = try AttachmentStore(directory: directory.appendingPathComponent("assets"))
                accountGeneration += 1
                repository = repo; attachments = assets
                sessions = [:]; summaries = []; notebooks = []
                savedSearches = []; savedSearchMatches = [:]; backlinks = [:]; noteGraph = NoteGraph()
                search = ""; fullTextMatches = []; resetAdvancedFilters()
            }
            await self.client?.disconnect()
            guard generation == connectionGeneration else { await client.disconnect(); return }
            hasVerifiedNASLists = false
            self.client = client; self.profile = newProfile; self.profile.persist(to: preferences)
            let credentials = SavedNASCredentials(password: newProfile.rememberPassword ? password : nil,
                                                 deviceID: newProfile.rememberDevice ? await client.trustedDeviceID : nil)
            trustedDeviceRemembered = false
            do {
                if credentials != prior { try await credentialAccess.save(credentials, newProfile.storageKey, !automatic) }
                guard generation == connectionGeneration else { return }
                trustedDeviceRemembered = credentials.deviceID != nil
                if newProfile.rememberDevice, credentials.deviceID == nil {
                    loginStorageMessage = appText("The NAS did not issue a trusted device token. You may need a verification code next time you sign in.")
                }
            } catch {
                // Credential persistence is optional; a keychain ACL failure
                // must not invalidate a successful NAS authentication.
                loginStorageIssue = .couldNotSave
                loginStorageMessage = appText("The NAS accepted the sign-in, but the app could not save the details in Keychain. Sign in again next time.")
            }
            guard generation == connectionGeneration else { return }
            isConnected = true
            logEvent(.connectionSucceeded)
            try await reload()
            // Refresh after clearing the connect progress flag.
            isRefreshing = false
            await refreshFromServer()
            startRefreshLoop()
            try configureUploads()
            startUploadLoop()
            scheduleUpload()
            startOfflineDownload()
        } catch {
            guard generation == connectionGeneration else { return }
            let retainedExistingConnection = wasConnected && self.client === previousClient && profile == previousProfile
            isConnected = retainedExistingConnection
            connectionStatus = retainedExistingConnection ? appText("NAS Connected · Could Not Switch Accounts") : appText("Sign-in Required")
            connectionError = error.localizedDescription
            lastConnectionFailure = error
            logEvent(.connectionFailed, error: error)
            if retainedExistingConnection {
                startOfflineDownload()
            } else if Self.isRecoverableConnectionError(error) {
                requestConnectionRecovery(after: error)
            } else if automatic {
                recoveryBlocked = true
            }
        }
    }

    func disconnect() async {
        logEvent(.disconnected)
        connectionGeneration += 1
        recoveryAllowed = false; stopConnectionRecovery(); cancelOfflineDownload()
        attemptedStartupConnection = true
        isRefreshing = false
        trustedDeviceRemembered = false
        refreshTask?.cancel()
        uploadTask?.cancel(); uploadLoop?.cancel(); syncCoordinator = nil; uploadTransport = nil; isPushing = false; uploadProgress = nil; uploadError = nil
        let previous = client
        client = nil; isConnected = false; hasVerifiedNASLists = false; connectionStatus = appText("Disconnected from NAS")
        await previous?.disconnect()
    }

    func persistLoginPreferences(from options: ConnectionProfile) {
        guard options.storageKey == profile.storageKey else { return }
        profile.autoConnect = options.autoConnect
        profile.rememberPassword = options.rememberPassword
        profile.rememberDevice = options.rememberDevice
        profile.keepOffline = options.keepOffline
        profile.persist(to: preferences)
        if !profile.autoConnect || !profile.rememberPassword { stopConnectionRecovery() }
    }

    func refreshFromServer() async {
        guard let client, isConnected, !isRefreshing, !isPushing, !isManagingStacks, deletingNotebookIDs.isEmpty, deletingNoteIDs.isEmpty else { return }
        isRefreshing = true; connectionStatus = appText("Checking NAS List…")
        let generation = accountGeneration, connection = connectionGeneration, repo = repository
        var receivedLists = false
        defer {
            if connection == connectionGeneration, self.client === client {
                isRefreshing = false; scheduleUpload()
                if isConnected { startOfflineDownload() }
            }
        }
        do {
            async let remoteBooks = client.notebooks()
            async let remoteNotes = client.notes()
            let (books, notes) = try await (remoteBooks, remoteNotes)
            guard generation == accountGeneration, connection == connectionGeneration, self.client === client else { return }
            receivedLists = true
            if !Task.isCancelled, isConnected { hasVerifiedNASLists = true }
            let localBooks = try await repo.notebooks().filter { $0.id == "local" || $0.id.hasPrefix("local-") }
            try await repo.setNotebooks(books.map { Notebook(id: $0.id, name: $0.name, stack: $0.stack) } + localBooks)
            for summary in notes {
                try await repo.observeRemote(Self.record(from: summary))
            }
            try await reload()
            connectionStatus = appText("NAS Connected · Reading Available")
            connectionError = nil
            logEvent(.refreshCompleted, fields: ["count": String(notes.count)])
            // Open documents refresh independently; closed notes remain metadata-only.
            for session in Array(sessions.values) where session.note.remoteID != nil && session.note.mode != .locked {
                if let metadata = try await repo.note(id: session.id), metadata.listedVersion != session.note.serverVersion {
                    await fetchContent(for: session)
                }
            }
            if isConnected { recoveryStartedAt = nil; recoveryExpired = false }
        } catch {
            guard generation == accountGeneration, connection == connectionGeneration, self.client === client else { return }
            if !receivedLists, !Task.isCancelled, !(error is CancellationError),
               let failure = error as? NoteStationError, failure != .cancelled, failure != .connectionChanged {
                hasVerifiedNASLists = false
            }
            connectionStatus = appText("Could not check the NAS")
            connectionError = error.localizedDescription
            logEvent(.refreshFailed, error: error)
            if Self.isRecoverableConnectionError(error) { requestConnectionRecovery(after: error) }
        }
    }

    func createNASWriteValidationNote(notebookID: String) async throws -> NASWriteValidationResult {
        guard let client, isConnected else { throw NoteStationError.notConnected }
        guard notebookID != "local", !notebookID.hasPrefix("local-") else {
            throw NoteStationError.invalidArgument("notebookID")
        }
        let generation = accountGeneration
        let marker = String(UUID().uuidString.lowercased().prefix(8))
        let title = "[SynologyNote 검증] \(marker)"
        let html = "<p>SynologyNote NAS 쓰기 호환성 검증입니다.</p><p>marker: \(marker)</p>"
        let receipt = try await client.createValidationNote(notebookID: notebookID, title: title, html: html)
        guard generation == accountGeneration else { throw NoteStationError.connectionChanged }
        connectionError = nil
        await refreshFromServer()
        guard generation == accountGeneration else { throw NoteStationError.connectionChanged }
        let confirmed = summaries.contains { $0.remoteID == receipt.objectID }
        return NASWriteValidationResult(receipt: receipt, confirmedInList: confirmed)
    }

    func validateNASNoteEditing(notebookID: String) async throws -> NoteEditingValidationReport {
        guard let client, isConnected else { throw NoteStationError.notConnected }
        guard notebooks.contains(where: { $0.id == notebookID }),
              notebookID != "local", !notebookID.hasPrefix("local-") else {
            throw NoteStationError.invalidArgument("notebookID")
        }
        let generation = accountGeneration
        let reportURL = root.appendingPathComponent(profile.storageKey).appendingPathComponent("nas-editing-validation.json")
        let report = try await client.validateNoteEditing(notebookID: notebookID)
        guard generation == accountGeneration, self.client === client, isConnected else {
            throw NoteStationError.connectionChanged
        }
        // Keep diagnostic evidence across restarts without storing document bodies.
        do { try JSONEncoder().encode(report).write(to: reportURL, options: .atomic) }
        catch { errorMessage = appText("Could not save the check result file: ") + error.localizedDescription }
        await refreshFromServer()
        guard generation == accountGeneration, self.client === client else { throw NoteStationError.connectionChanged }
        return report
    }

    func lastNASNoteEditingValidation() -> NoteEditingValidationReport? {
        let url = root.appendingPathComponent(profile.storageKey).appendingPathComponent("nas-editing-validation.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NoteEditingValidationReport.self, from: data)
    }

    func validateNASNoteAttachments(notebookID: String) async throws -> NoteAttachmentValidationReport {
        guard let client, isConnected else { throw NoteStationError.notConnected }
        guard notebooks.contains(where: { $0.id == notebookID }), notebookID != "local", !notebookID.hasPrefix("local-") else {
            throw NoteStationError.invalidArgument("notebookID")
        }
        let generation = accountGeneration
        let url = root.appendingPathComponent(profile.storageKey).appendingPathComponent("nas-attachment-validation.json")
        let report = try await client.validateNoteAttachments(notebookID: notebookID)
        guard generation == accountGeneration, self.client === client, isConnected else { throw NoteStationError.connectionChanged }
        do { try JSONEncoder().encode(report).write(to: url, options: .atomic) }
        catch { errorMessage = appText("Could not save the attachment check record: ") + error.localizedDescription }
        await refreshFromServer()
        guard generation == accountGeneration, self.client === client else { throw NoteStationError.connectionChanged }
        return report
    }

    func lastNASNoteAttachmentValidation() -> NoteAttachmentValidationReport? {
        let url = root.appendingPathComponent(profile.storageKey).appendingPathComponent("nas-attachment-validation.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NoteAttachmentValidationReport.self, from: data)
    }

    func fetchContent(for session: EditorSession) async {
        if let task = session.downloadTask { await task.value; return }
        session.isDownloading = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.downloadContent(for: session)
        }
        session.downloadTask = task
        defer { session.downloadTask = nil; session.isDownloading = false }
        await task.value
    }

    func waitForMarkdownPublication(for session: EditorSession, initialDelay: Duration = .seconds(5)) async {
        let generation = connectionGeneration
        var delay = initialDelay
        while session.isWaitingForMarkdownSource, isConnected, connectionGeneration == generation {
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, session.isWaitingForMarkdownSource, isConnected,
                  connectionGeneration == generation else { return }
            await fetchContent(for: session)
            delay = min(delay * 2, .seconds(60))
        }
    }

    private func downloadContent(for session: EditorSession) async {
        guard let client, let remoteID = session.note.remoteID else { return }
        let account = accountGeneration, connection = connectionGeneration, repo = repository, assets = attachments
        guard session.workspaceGeneration == account else { return }
        do {
            guard let baseline = try await repo.note(id: session.id),
                  try await !repo.syncAttempts().contains(where: { $0.note.id == session.id }) else { return }
            var incoming = try await Self.downloadedRecord(noteID: remoteID, client: client, repo: repo, assets: assets)
            incoming.id = session.id
            guard account == accountGeneration, connection == connectionGeneration, self.client === client, session.workspaceGeneration == account else { return }
            await save(session)
            guard account == accountGeneration, connection == connectionGeneration, self.client === client, session.workspaceGeneration == account else { return }
            guard try await !repo.syncAttempts().contains(where: { $0.note.id == session.id }) else { return }
            let mergeGeneration = session.editGeneration
            let merged = try await repo.mergeRemote(incoming, ifUnchangedFrom: baseline)
            guard account == accountGeneration, connection == connectionGeneration, self.client === client, session.workspaceGeneration == account else { return }
            session.isWaitingForMarkdownSource = false
            if session.editGeneration == mergeGeneration {
                session.note = merged
            } else {
                var current = session.note
                let snapshot = merged.conflictSnapshot ?? RemoteConflictSnapshot(
                    html: incoming.originalHTML,
                    version: incoming.serverVersion,
                    attachments: incoming.attachments
                )
                current.conflictHTML = snapshot.html
                current.conflictVersion = snapshot.version
                current.conflictSnapshot = snapshot
                current.syncState = .conflict
                current.lastError = appText("This note changed on this Mac while its body was downloading. Review both versions.")
                session.note = current
                await save(session)
            }
            try await reload()
        } catch RemoteContentPending.markdownPublication {
            guard account == accountGeneration, connection == connectionGeneration, self.client === client else { return }
            session.isWaitingForMarkdownSource = true
        } catch {
            guard account == accountGeneration, connection == connectionGeneration, self.client === client else { return }
            session.saveError = nil
            session.note.lastError = appText("Could not download the note body from the NAS: ") + error.localizedDescription
            connectionError = error.localizedDescription
            if Self.isRecoverableConnectionError(error) { requestConnectionRecovery(after: error) }
        }
    }

    static func record(from summary: RemoteNoteSummary) -> NoteRecord {
        var note = NoteRecord(title: summary.title, notebookID: summary.notebookID, mode: summary.isLocked ? .locked : .original)
        note.remoteID = summary.id; note.serverVersion = summary.version; note.listedVersion = summary.version
        note.createdAt = summary.createdAt
        note.modifiedAt = summary.modifiedAt; note.tags = summary.tags
        note.isFavorite = summary.isFavorite; note.isTrashed = summary.isTrashed
        return note
    }
    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                await self.refreshFromServer()
            }
        }
    }
}
