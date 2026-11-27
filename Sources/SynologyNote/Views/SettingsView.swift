import SwiftUI
import NoteCore

struct SettingsView: View {
    private enum SavedLoginAvailability {
        case checking, available, missing, needsKeychainAccess
    }

    @Environment(LibraryStore.self) private var library
    @State private var profile = ConnectionProfile.load()
    @State private var password = ""
    @State private var otp = ""
    @State private var isConnecting = false
    @State private var isEditingAccount = false
    @State private var savedLoginAvailability: SavedLoginAvailability = .checking
    @State private var isValidationExpanded = true
    @State private var validationStatus: String?
    @State private var showWriteValidationConfirmation = false
    @State private var isValidatingWrite = false
    @State private var writeValidationMessage: String? = nil
    @State private var showEditingValidationConfirmation = false
    @State private var editingValidationReport: NoteEditingValidationReport?
    @State private var showAttachmentValidationConfirmation = false
    @State private var attachmentValidationReport: NoteAttachmentValidationReport?
    @State private var showAutomaticUploadValidation = false
    @State private var automaticUploadMessage: String?
    @AppStorage(DisplayLanguagePreference.key, store: NoteLocalization.preferences)
    private var displayLanguage: DisplayLanguagePreference = .system
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("mermaidStyle") private var mermaidStyle: MermaidStyle = .sketch
    @AppStorage("mermaidTheme") private var mermaidTheme: MermaidTheme = .automatic

    private var canUseSavedLogin: Bool {
        profile.rememberPassword && profile.storageKey == library.profile.storageKey
            && !profile.server.isEmpty && !profile.username.isEmpty
            && savedLoginAvailability != .missing
    }

    private var showsAccountEditor: Bool {
        isEditingAccount || (!library.isConnected && !canUseSavedLogin)
    }

    private var connectionBusy: Bool {
        isConnecting || library.isRefreshing || library.isPushing || isValidatingWrite
    }

    private func connectWithEnteredAccount() {
        guard !connectionBusy else { return }
        isConnecting = true
        library.connectionError = nil
        library.connectionStatus = appText("Preparing to Connect…")
        let submittedProfile = profile
        let submittedPassword = password
        let submittedOTP = otp
        Task { @MainActor in
            defer { isConnecting = false }
            await library.connect(profile: submittedProfile, password: submittedPassword, otp: submittedOTP)
            if library.isConnected && library.profile == submittedProfile && library.connectionError == nil {
                profile = library.profile
                password = ""
                otp = ""
                savedLoginAvailability = submittedProfile.rememberPassword
                    && library.loginStorageIssue != .couldNotSave
                    ? .available : .missing
                isEditingAccount = false
            }
        }
    }

    private func reconnectSavedAccount() {
        guard !connectionBusy else { return }
        Task {
            await library.connectUsingSavedAccount()
            if library.loginStorageIssue == .missingPassword {
                savedLoginAvailability = .missing
            }
        }
    }

    private func cancelAccountEditing() {
        profile = library.profile
        password = ""
        otp = ""
        isEditingAccount = false
    }

    private var connectionSection: some View {
        Section(appText("Connection Status")) {
            HStack(spacing: 12) {
                Image(systemName: library.isConnected ? "checkmark.circle.fill" : "externaldrive")
                    .font(.title2)
                    .foregroundStyle(library.isConnected ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.isConnected ? appText("Connected to NAS") : library.isRefreshing || isConnecting ? appText("Connecting…") : appText("Disconnected"))
                        .font(.headline)
                    Text(library.connectionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                if library.isRefreshing || isConnecting {
                    ProgressView().controlSize(.small)
                }
                if library.isConnected {
                    Button(appText("Disconnect")) { Task { await library.disconnect() } }
                        .disabled(connectionBusy)
                } else if canUseSavedLogin && !isEditingAccount {
                    Button(savedLoginAvailability == .checking ? appText("Checking Account…") : appText("Reconnect"), action: reconnectSavedAccount)
                        .buttonStyle(.borderedProminent)
                        .disabled(connectionBusy || savedLoginAvailability == .checking)
                }
            }
            if let error = library.connectionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let message = library.loginStorageMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var accountSection: some View {
        Section(appText("NAS Account")) {
            if showsAccountEditor {
                TextField(appText("NAS Address"), text: $profile.server, prompt: Text("https://nas.example.com:5001"))
                    .textContentType(.URL)
                    .disabled(connectionBusy)
                TextField(appText("Username"), text: $profile.username).textContentType(.username)
                    .disabled(connectionBusy)
                SecureField(appText("Password"), text: $password).textContentType(.password)
                    .disabled(connectionBusy)
                TextField(appText("Two-Factor Authentication Code"), text: $otp, prompt: Text(appText("Enter when required")))
                    .disabled(connectionBusy)
                HStack(spacing: 10) {
                    Button(library.isConnected ? appText("Switch to This Account") : appText("Sign In"), action: connectWithEnteredAccount)
                        .buttonStyle(.borderedProminent)
                        .disabled(connectionBusy || profile.server.isEmpty || profile.username.isEmpty || password.isEmpty)
                    if isEditingAccount {
                        Button(appText("Cancel"), action: cancelAccountEditing)
                            .disabled(connectionBusy)
                    }
                }
            } else {
                LabeledContent(appText("NAS Address"), value: profile.server)
                LabeledContent(appText("User"), value: profile.username)
                Button(appText("Edit Account Details…")) { isEditingAccount = true }
                    .disabled(connectionBusy)
            }
        }
    }

    private var loginOptionsSection: some View {
        Section(appText("Sign-in Options")) {
            Toggle(appText("Save Password in Keychain"), isOn: $profile.rememberPassword)
            Toggle(appText("Connect Automatically on Launch"), isOn: $profile.autoConnect)
                .disabled(!profile.rememberPassword)
            Toggle(appText("Remember This Mac"), isOn: $profile.rememberDevice)
            Text(appText("Remembering this Mac can reduce two-factor prompts if the NAS supports it."))
                .font(.caption).foregroundStyle(.secondary)
            if library.trustedDeviceRemembered {
                Label(appText("Trusted Device Token Saved in Keychain"), systemImage: "checkmark.shield")
                    .font(.caption)
            }
        }
    }

    var body: some View {
        TabView {
            Form {
                connectionSection
                accountSection
                loginOptionsSection
                Section(appText("Offline Access")) {
                    Toggle(appText("Keep All Note Content and Attachments on This Mac"), isOn: Binding(
                        get: { library.profile.keepOffline },
                        set: { profile.keepOffline = $0; library.setOfflineStorage($0) }))
                    Text(appText("Download unopened notes for body search and offline access. Encrypted notes are excluded."))
                        .font(.caption).foregroundStyle(.secondary)
                    if library.isCachingOffline {
                        ProgressView(value: Double(library.offlineCompleted), total: Double(max(1, library.offlineTotal)))
                    }
                    Text(library.offlineStatus).font(.caption).foregroundStyle(.secondary)
                    if !library.offlineFailures.isEmpty {
                        Text(appText("Notes with missing content or attachments: %@. Downloaded notes remain available.", AppLocalization.number(library.offlineFailures.count)))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button(appText("Retry Incomplete Downloads")) { library.startOfflineDownload() }
                        .disabled(!library.isConnected || library.isCachingOffline || !library.profile.keepOffline)
                }
                Section(appText("Sync")) {
                    Label(appText("Edits Sync with the NAS Automatically"), systemImage: "arrow.triangle.2.circlepath")
                    Text(appText("Edits are kept on this Mac while offline and uploaded after reconnection. Conflicting changes are preserved."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(library.uploadStatus).font(.caption).foregroundStyle(.secondary)
                    if let uploadError = library.uploadError {
                        Text(uploadError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let queueStatus = library.uploadQueueStatus {
                        Text(queueStatus).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button(appText("Sync Now and Verify")) { Task { await library.pushPendingUploads() } }
                        .disabled(!library.isConnected || !library.automaticUploadReady || library.isPushing || isValidatingWrite)
                }
            }.formStyle(.grouped).tabItem { Label("Note Station", systemImage: "externaldrive.connected.to.line.below") }
            Form {
                DiagnosticLogSettingsSection()
                Section(appText("Diagnostic Logs")) {
                    Button(appText("Open Log Folder")) { library.openLogDirectory() }
                    Text(appText("Logs record connection, save, automatic sync, and database maintenance operations. Passwords, verification codes, tokens, and note bodies are excluded. Rotation and retention limits apply."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(library.logDirectory.path).font(.caption).textSelection(.enabled)
                    if let error = library.diagnosticLog?.writeError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                DiagnosticExportSection()
                if library.isConnected {
                    Section {
                        DisclosureGroup(isExpanded: $isValidationExpanded) {
                            Text(appText("The first check creates a dedicated SynologyNote test notebook on the NAS. Later checks reuse it. Existing notebooks and notes are skipped, and test notes are kept for review."))
                                .foregroundStyle(.secondary)
                            Button {
                                showWriteValidationConfirmation = true
                            } label: {
                                HStack(spacing: 7) {
                                    if isValidatingWrite { ProgressView().controlSize(.small) }
                                    Text(isValidatingWrite ? appText("Checking…") : appText("Create Test Note"))
                                }
                            }
                            .disabled(isValidatingWrite || library.isRefreshing)
                            Button(appText("Check Updates and Conflicts…")) { showEditingValidationConfirmation = true }
                                .disabled(isValidatingWrite || library.isRefreshing)
                            Button(appText("Check Image and Markdown Round-trip…")) { showAttachmentValidationConfirmation = true }
                                .disabled(isValidatingWrite || library.isRefreshing)
                            Button(appText("Verify Automatic Upload…")) { showAutomaticUploadValidation = true }
                                .disabled(isValidatingWrite || library.isRefreshing || library.isPushing || !library.automaticUploadReady)
                            if let writeValidationMessage {
                                Text(writeValidationMessage).font(.caption).textSelection(.enabled)
                            }
                            if let editingValidationReport {
                                NASValidationReportView(report: editingValidationReport)
                            }
                            if let attachmentValidationReport {
                                NASAttachmentValidationReportView(report: attachmentValidationReport)
                            }
                            if let automaticUploadMessage { Text(automaticUploadMessage).font(.caption).textSelection(.enabled) }
                        } label: {
                            HStack {
                                Text(appText("NAS Write Compatibility Check"))
                                Spacer()
                                if isValidatingWrite { ProgressView().controlSize(.small) }
                                if let validationStatus {
                                    Text(validationStatus).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label(appText("Diagnostics"), systemImage: "stethoscope") }
            Form {
                Section(appText("Language")) {
                    Picker(appText("Display Language"), selection: $displayLanguage) {
                        Text(appText("System Default")).tag(DisplayLanguagePreference.system)
                        Text(verbatim: "English").tag(DisplayLanguagePreference.english)
                        Text(verbatim: "한국어").tag(DisplayLanguagePreference.korean)
                    }
                    if displayLanguage != NoteLocalization.launchPreference {
                        Text(appText("Quit and reopen the app to apply the language change."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(appText("Editor")) {
                    Slider(value: $fontSize, in: 11...22, step: 1) { Text(appText("Font Size")) }
                    Text(appText("%@ pt · Monospaced Markdown Font", AppLocalization.number(Int(fontSize)))).foregroundStyle(.secondary)
                    Picker(appText("Appearance"), selection: $appearance) {
                        Text(appText("System Setting")).tag("system"); Text(appText("Light")).tag("light"); Text(appText("Dark")).tag("dark")
                    }
                }
                Section(appText("Mermaid Diagrams")) {
                    Picker(appText("Drawing Style"), selection: $mermaidStyle) {
                        ForEach(MermaidStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    Picker(appText("Color Theme"), selection: $mermaidTheme) {
                        ForEach(MermaidTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    Text(appText("Changes apply to the preview immediately. Sketch gives shapes and lines a hand-drawn look in supported diagrams."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(appText("Save")) {
                    Text(appText("Note bodies, revisions, and pending uploads are saved together in SQLite transactions. Attachments are copied to app storage.")).foregroundStyle(.secondary)
                    Button(appText("Show Local Storage")) { NSWorkspace.shared.open(LibraryStore.storageRoot()) }
                }
                if let version = AppVersion.display {
                    Section(appText("About the App")) {
                        LabeledContent(appText("Version"), value: version)
                    }
                }
            }.formStyle(.grouped).tabItem { Label(appText("General"), systemImage: "slider.horizontal.3") }
        }.frame(width: 590, height: 570)
        .alert(appText("Create a Test Note on the NAS?"), isPresented: $showWriteValidationConfirmation) {
            Button(appText("Cancel"), role: .cancel) {}
            Button(appText("Create")) {
                isValidatingWrite = true
                writeValidationMessage = nil
                validationStatus = nil
                Task { @MainActor in
                    defer { isValidatingWrite = false }
                    do {
                        let notebook = try await library.ensureNASValidationNotebook()
                        let result = try await library.createNASWriteValidationNote(notebookID: notebook.id)
                        writeValidationMessage = result.confirmedInList
                            ? appText("Created “%@” and verified it in the refreshed list.", result.receipt.title)
                            : appText("The creation request succeeded, but the note could not be verified in the refreshed list. Check for “%@” on the NAS before repeating the test.", result.receipt.title)
                        finishValidation(passed: result.confirmedInList)
                    } catch {
                        writeValidationMessage = appText("Check failed: %@", error.localizedDescription)
                        validationStatus = appText("Check Error")
                        isValidationExpanded = true
                    }
                }
            }
        } message: {
            Text(appText("The first check creates a dedicated notebook on the NAS. Each check creates one test note in that notebook. Existing notebooks and notes are left alone."))
        }
        .alert(appText("Run the NAS Update and Conflict Check?"), isPresented: $showEditingValidationConfirmation) {
            Button(appText("Cancel"), role: .cancel) {}
            Button(appText("Run Check")) { runEditingValidation() }
        } message: {
            Text(appText("This creates a test note, updates its body, and checks that the NAS rejects saves using an older version. The first check also creates the test notebook. The test note is kept."))
        }
        .alert(appText("Run the Image and Markdown Round-trip Check?"), isPresented: $showAttachmentValidationConfirmation) {
            Button(appText("Cancel"), role: .cancel) {}
            Button(appText("Run Check")) { runAttachmentValidation() }
        } message: {
            Text(appText("This creates a test note, uploads a small PNG and the Markdown source, and downloads them for verification. The first check also creates the test notebook. The test note is kept."))
        }
        .alert(appText("Run Automatic Upload Diagnostics?"), isPresented: $showAutomaticUploadValidation) {
            Button(appText("Cancel"), role: .cancel) {}
            Button(appText("Run Verification")) { runAutomaticUploadValidation() }
        } message: {
            Text(appText("This creates a test note and checks content, attachments, edits, tags, and recovery from a lost response. The first check also creates the test notebook. Automatic upload is always enabled."))
        }
        .task {
            profile = library.profile
            restoreValidationReports()
        }
        .task(id: library.profile.storageKey + (library.profile.rememberPassword ? ":remember" : ":manual")
              + (library.isConnected ? ":connected" : ":disconnected")) {
            let savedProfile = library.profile
            let key = savedProfile.storageKey
            savedLoginAvailability = .checking
            guard savedProfile.rememberPassword, !savedProfile.server.isEmpty, !savedProfile.username.isEmpty else {
                savedLoginAvailability = .missing
                return
            }
            do {
                let credentials = try await library.credentialAccess.load(key)
                guard !Task.isCancelled, key == library.profile.storageKey else { return }
                savedLoginAvailability = credentials?.password?.isEmpty == false ? .available : .missing
            } catch {
                // Interactive Keychain access may succeed even if the background read is denied.
                if !Task.isCancelled, key == library.profile.storageKey { savedLoginAvailability = .needsKeychainAccess }
            }
        }
        .onChange(of: profile.storageKey) { _, _ in password = "" }
        .onChange(of: profile.autoConnect) { _, _ in
            if !isEditingAccount { library.persistLoginPreferences(from: profile) }
        }
        .onChange(of: profile.rememberDevice) { _, _ in
            if !isEditingAccount { library.persistLoginPreferences(from: profile) }
        }
        .onChange(of: profile.rememberPassword) { _, _ in
            if !isEditingAccount { library.persistLoginPreferences(from: profile) }
        }
        .onChange(of: library.profile) { _, updated in
            if !isEditingAccount { profile = updated }
        }
        .onChange(of: library.profile.storageKey) { _, _ in
            writeValidationMessage = nil
            restoreValidationReports()
        }
    }

    private func finishValidation(passed: Bool) {
        validationStatus = passed ? appText("Check Complete") : appText("Needs Review")
        isValidationExpanded = false
    }

    private func restoreValidationReports() {
        editingValidationReport = library.lastNASNoteEditingValidation()
        attachmentValidationReport = library.lastNASNoteAttachmentValidation()
        let uploadReport = library.lastAutomaticUploadValidation()
        automaticUploadMessage = uploadReport.map(automaticResult)
        let outcomes = [editingValidationReport?.passed, attachmentValidationReport?.passed, uploadReport?.passed].compactMap { $0 }
        validationStatus = outcomes.isEmpty ? nil : (outcomes.allSatisfy { $0 } ? appText("Check Complete") : appText("Needs Review"))
        isValidationExpanded = outcomes.isEmpty
    }

    private func runEditingValidation() {
        guard !isValidatingWrite else { return }
        isValidatingWrite = true
        writeValidationMessage = appText("Saving and fetching the update, trying an older version, and checking the latest content…")
        editingValidationReport = nil
        validationStatus = nil
        Task { @MainActor in
            defer { isValidatingWrite = false }
            do {
                let notebook = try await library.ensureNASValidationNotebook()
                let report = try await library.validateNASNoteEditing(notebookID: notebook.id)
                editingValidationReport = report
                writeValidationMessage = report.passed
                    ? appText("The update and conflict check passed. The next step is the attachment round-trip check.")
                    : appText("The check failed. Review the note below on the NAS before trying again.")
                finishValidation(passed: report.passed)
            } catch {
                writeValidationMessage = appText("Check stopped: %@. A test note may already exist. Check the NAS before trying again.", error.localizedDescription)
                validationStatus = appText("Check Error")
                isValidationExpanded = true
            }
        }
    }

    private func runAttachmentValidation() {
        guard !isValidatingWrite else { return }
        isValidatingWrite = true
        attachmentValidationReport = nil
        writeValidationMessage = appText("Uploading and downloading the image, saving Markdown, and checking restored attachment links…")
        validationStatus = nil
        Task { @MainActor in
            defer { isValidatingWrite = false }
            do {
                let notebook = try await library.ensureNASValidationNotebook()
                let report = try await library.validateNASNoteAttachments(notebookID: notebook.id)
                attachmentValidationReport = report
                writeValidationMessage = report.passed ? appText("Image and Markdown Round-trip Check Passed") : appText("The attachment check failed. Review the results below.")
                finishValidation(passed: report.passed)
            } catch {
                writeValidationMessage = appText("Attachment check stopped: %@. Check the test note on the NAS before trying again.", error.localizedDescription)
                validationStatus = appText("Check Error")
                isValidationExpanded = true
            }
        }
    }
    private func runAutomaticUploadValidation() {
        guard !isValidatingWrite else { return }
        isValidatingWrite = true; automaticUploadMessage = appText("Checking creation, edits, and recovery from a lost response…")
        validationStatus = nil
        Task { @MainActor in
            defer { isValidatingWrite = false }
            do {
                let notebook = try await library.ensureNASValidationNotebook()
                let report = try await library.validateAutomaticUpload(notebookID: notebook.id)
                automaticUploadMessage = automaticResult(report)
                finishValidation(passed: report.passed)
            } catch {
                automaticUploadMessage = appText("Check stopped: %@", error.localizedDescription)
                validationStatus = appText("Check Error")
                isValidationExpanded = true
            }
        }
    }
    private func automaticResult(_ report: AutomaticUploadValidation) -> String {
        appText("Automatic Upload: %1$@ · Creation: %2$@ · Update: %3$@ · Duplicate-free recovery: %4$@\nNote ID: %5$@\n%6$@", "\(report.passed ? appText("Passed") : appText("Needs Review"))", "\(report.createVerified ? appText("OK") : appText("Unverified"))", "\(report.updateVerified ? appText("OK") : appText("Unverified"))", "\(report.lostResponseRecovered ? appText("OK") : appText("Unverified"))", "\(report.remoteID ?? appText("Unverified"))", "\(report.failure ?? "")")
    }
}

private struct NASAttachmentValidationReportView: View {
    let report: NoteAttachmentValidationReport
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appText("Attachment Check · ") + AppLocalization.date(report.checkedAt)).foregroundStyle(.secondary)
            Label(appText("Image bytes: %@", "\(report.imageBytesVerified ? appText("OK") : appText("Unverified"))"), systemImage: report.imageBytesVerified ? "checkmark.circle.fill" : "questionmark.circle")
            Label(appText("Markdown source bytes: %@", "\(report.sourceBytesVerified ? appText("OK") : appText("Unverified"))"), systemImage: report.sourceBytesVerified ? "checkmark.circle.fill" : "questionmark.circle")
            Label(appText("Markdown and image link restored: %@", "\(report.markdownRestored ? appText("OK") : appText("Unverified"))"), systemImage: report.markdownRestored ? "checkmark.circle.fill" : "questionmark.circle")
            Text(report.receipt.title).textSelection(.enabled)
            Text(appText("Note ID: %@", "\(report.receipt.objectID)")).textSelection(.enabled).foregroundStyle(.secondary)
            if let failure = report.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
        }.font(.caption)
    }
}

private struct NASValidationReportView: View {
    let report: NoteEditingValidationReport
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.date(report.checkedAt)).foregroundStyle(.secondary)
            status(appText("Save and Fetch Update"), confirmed: report.updateConfirmed)
            status(appText("Older Version Rejected (1064)"), confirmed: report.conflictRejected)
            status(appText("Latest Content and Version Kept"), confirmed: report.latestContentPreserved)
            Text(report.receipt.title).textSelection(.enabled)
            Text(appText("Note ID: %@", "\(report.receipt.objectID)")).textSelection(.enabled).foregroundStyle(.secondary)
            if let failure = report.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
        }.font(.caption)
    }
    private func status(_ title: String, confirmed: Bool) -> some View {
        Label("\(title): \(confirmed ? appText("OK") : appText("Unverified"))", systemImage: confirmed ? "checkmark.circle.fill" : "questionmark.circle")
            .foregroundStyle(confirmed ? Color.green : Color.secondary)
    }
}
