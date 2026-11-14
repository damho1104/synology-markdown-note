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
        library.connectionStatus = "연결 준비 중…"
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
                    && !(library.loginStorageMessage?.contains("키체인에 저장하지 못했습니다") ?? false)
                    ? .available : .missing
                isEditingAccount = false
            }
        }
    }

    private func reconnectSavedAccount() {
        guard !connectionBusy else { return }
        Task {
            await library.connectUsingSavedAccount()
            if library.loginStorageMessage?.contains("저장된 비밀번호가 없습니다") == true {
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
        Section("연결 상태") {
            HStack(spacing: 12) {
                Image(systemName: library.isConnected ? "checkmark.circle.fill" : "externaldrive")
                    .font(.title2)
                    .foregroundStyle(library.isConnected ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.isConnected ? "NAS에 연결됨" : library.isRefreshing || isConnecting ? "연결 중…" : "연결 안 됨")
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
                    Button("연결 해제") { Task { await library.disconnect() } }
                        .disabled(connectionBusy)
                } else if canUseSavedLogin && !isEditingAccount {
                    Button(savedLoginAvailability == .checking ? "계정 확인 중…" : "다시 연결", action: reconnectSavedAccount)
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
        Section("NAS 계정") {
            if showsAccountEditor {
                TextField("NAS 주소", text: $profile.server, prompt: Text("https://nas.example.com:5001"))
                    .textContentType(.URL)
                    .disabled(connectionBusy)
                TextField("사용자 이름", text: $profile.username).textContentType(.username)
                    .disabled(connectionBusy)
                SecureField("비밀번호", text: $password).textContentType(.password)
                    .disabled(connectionBusy)
                TextField("2단계 인증 코드", text: $otp, prompt: Text("필요할 때만 입력"))
                    .disabled(connectionBusy)
                HStack(spacing: 10) {
                    Button(library.isConnected ? "이 계정으로 전환" : "로그인", action: connectWithEnteredAccount)
                        .buttonStyle(.borderedProminent)
                        .disabled(connectionBusy || profile.server.isEmpty || profile.username.isEmpty || password.isEmpty)
                    if isEditingAccount {
                        Button("취소", action: cancelAccountEditing)
                            .disabled(connectionBusy)
                    }
                }
            } else {
                LabeledContent("NAS 주소", value: profile.server)
                LabeledContent("사용자", value: profile.username)
                Button("계정 정보 수정…") { isEditingAccount = true }
                    .disabled(connectionBusy)
            }
        }
    }

    private var loginOptionsSection: some View {
        Section("로그인 옵션") {
            Toggle("비밀번호를 키체인에 보관", isOn: $profile.rememberPassword)
            Toggle("앱을 열면 자동 연결", isOn: $profile.autoConnect)
                .disabled(!profile.rememberPassword)
            Toggle("이 Mac 기억하기", isOn: $profile.rememberDevice)
            Text("기기 기억을 사용하면 NAS에서 지원하는 경우 2단계 인증 코드 입력을 줄일 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            if library.trustedDeviceRemembered {
                Label("기기 기억 토큰이 키체인에 저장됨", systemImage: "checkmark.shield")
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
                Section("오프라인 보관") {
                    Toggle("전체 노트 본문·첨부를 이 Mac에 보관", isOn: Binding(
                        get: { library.profile.keepOffline },
                        set: { profile.keepOffline = $0; library.setOfflineStorage($0) }))
                    Text("아직 열지 않은 노트도 내려받아 본문 검색과 오프라인 열기를 지원합니다. 암호화된 노트는 제외합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    if library.isCachingOffline {
                        ProgressView(value: Double(library.offlineCompleted), total: Double(max(1, library.offlineTotal)))
                    }
                    Text(library.offlineStatus).font(.caption).foregroundStyle(.secondary)
                    if !library.offlineFailures.isEmpty {
                        Text("\(library.offlineFailures.count)개 노트의 본문 또는 첨부를 받지 못했습니다. 받은 노트는 계속 사용할 수 있습니다.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("미완료 항목 다시 받기") { library.startOfflineDownload() }
                        .disabled(!library.isConnected || library.isCachingOffline || !library.profile.keepOffline)
                }
                Section("동기화") {
                    Label("편집 내용은 NAS에 자동 동기화됩니다", systemImage: "arrow.triangle.2.circlepath")
                    Text("연결이 끊겨도 이 Mac에 보관하며, 재연결 후 전송합니다. 충돌이 있으면 변경 내용을 보존합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(library.uploadStatus).font(.caption).foregroundStyle(.secondary)
                    Button("지금 동기화 · 반영 확인") { Task { await library.pushPendingUploads() } }
                        .disabled(!library.isConnected || !library.automaticUploadReady || library.isPushing || isValidatingWrite)
                }
            }.formStyle(.grouped).tabItem { Label("Note Station", systemImage: "externaldrive.connected.to.line.below") }
            Form {
                DiagnosticLogSettingsSection()
                Section("진단 로그") {
                    Button("로그 폴더 열기") { library.openLogDirectory() }
                    Text("연결·저장·자동 동기화·DB 관리 작업을 기록합니다. 비밀번호·OTP·인증 토큰·노트 본문은 기록하지 않습니다. 위의 회전·보관 한도에 따라 로그를 관리합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(library.logDirectory.path).font(.caption).textSelection(.enabled)
                    if let error = library.diagnosticLog?.writeError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                DiagnosticExportSection()
                if library.isConnected {
                    Section {
                        DisclosureGroup(isExpanded: $isValidationExpanded) {
                            Text("NAS에 SynologyNote 검사 전용 메모장을 처음 한 번 만들고 이후 재사용합니다. 기존 메모장과 노트는 검사하지 않으며, 검증 노트는 결과 확인을 위해 남깁니다.")
                                .foregroundStyle(.secondary)
                            Button {
                                showWriteValidationConfirmation = true
                            } label: {
                                HStack(spacing: 7) {
                                    if isValidatingWrite { ProgressView().controlSize(.small) }
                                    Text(isValidatingWrite ? "검증 중…" : "검증용 노트 생성")
                                }
                            }
                            .disabled(isValidatingWrite || library.isRefreshing)
                            Button("수정·충돌 검사…") { showEditingValidationConfirmation = true }
                                .disabled(isValidatingWrite || library.isRefreshing)
                            Button("이미지·Markdown 왕복 검사…") { showAttachmentValidationConfirmation = true }
                                .disabled(isValidatingWrite || library.isRefreshing)
                            Button("자동 업로드 검증…") { showAutomaticUploadValidation = true }
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
                                Text("NAS 쓰기 호환성 검사")
                                Spacer()
                                if isValidatingWrite { ProgressView().controlSize(.small) }
                                if let validationStatus {
                                    Text(validationStatus).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("진단", systemImage: "stethoscope") }
            Form {
                Section("편집기") {
                    Slider(value: $fontSize, in: 11...22, step: 1) { Text("글꼴 크기") }
                    Text("\(Int(fontSize))pt · Markdown 고정폭 글꼴").foregroundStyle(.secondary)
                    Picker("화면 모드", selection: $appearance) {
                        Text("시스템 설정").tag("system"); Text("라이트").tag("light"); Text("다크").tag("dark")
                    }
                }
                Section("Mermaid 다이어그램") {
                    Picker("그리기 스타일", selection: $mermaidStyle) {
                        ForEach(MermaidStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    Picker("색상 테마", selection: $mermaidTheme) {
                        ForEach(MermaidTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    Text("변경하면 미리보기에 바로 적용됩니다. 스케치는 지원되는 다이어그램의 도형과 선을 손으로 그린 듯 표시합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("저장") {
                    Text("본문·수정 이력·전송 대기는 SQLite 트랜잭션으로 함께 저장합니다. 첨부파일은 앱 전용 저장소에 복사됩니다.").foregroundStyle(.secondary)
                    Button("로컬 저장소 보기") { NSWorkspace.shared.open(LibraryStore.storageRoot()) }
                }
                if let version = AppVersion.display {
                    Section("앱 정보") {
                        LabeledContent("버전", value: version)
                    }
                }
            }.formStyle(.grouped).tabItem { Label("일반", systemImage: "slider.horizontal.3") }
        }.frame(width: 590, height: 570)
        .alert("NAS에 검증용 노트를 생성할까요?", isPresented: $showWriteValidationConfirmation) {
            Button("취소", role: .cancel) {}
            Button("생성") {
                isValidatingWrite = true
                writeValidationMessage = nil
                validationStatus = nil
                Task { @MainActor in
                    defer { isValidatingWrite = false }
                    do {
                        let notebook = try await library.ensureNASValidationNotebook()
                        let result = try await library.createNASWriteValidationNote(notebookID: notebook.id)
                        writeValidationMessage = result.confirmedInList
                            ? "성공: \(result.receipt.title) 생성 및 목록 재조회 확인 완료"
                            : "생성 응답은 성공했지만 목록 재조회로 확인하지 못했습니다. 같은 검사를 반복하지 말고 NAS에서 '\(result.receipt.title)'을 먼저 확인하세요."
                        finishValidation(passed: result.confirmedInList)
                    } catch {
                        writeValidationMessage = "검증 실패: \(error.localizedDescription)"
                        validationStatus = "검사 오류"
                        isValidationExpanded = true
                    }
                }
            }
        } message: {
            Text("첫 검사에서 NAS에 전용 검사 메모장을 만들고 이후 재사용합니다. 이 메모장에 검증 노트 1개를 생성하며 기존 메모장과 노트는 수정하지 않습니다.")
        }
        .alert("NAS 수정·충돌 검사를 실행할까요?", isPresented: $showEditingValidationConfirmation) {
            Button("취소", role: .cancel) {}
            Button("검사 실행") { runEditingValidation() }
        } message: {
            Text("검사 전용 메모장에 '[SynologyNote 검증] 수정·충돌' 노트 1개를 만든 뒤 본문 수정과 이전 버전 저장 거절을 검사합니다. 처음에는 검사 메모장도 생성하며 결과 노트는 남깁니다.")
        }
        .alert("이미지·Markdown 왕복 검사를 실행할까요?", isPresented: $showAttachmentValidationConfirmation) {
            Button("취소", role: .cancel) {}
            Button("검사 실행") { runAttachmentValidation() }
        } message: {
            Text("검사 전용 메모장에 검증 노트를 만들고 작은 PNG와 Markdown 원문을 첨부한 뒤 다운로드해 확인합니다. 처음에는 검사 메모장도 생성하며 결과 노트는 남깁니다.")
        }
        .alert("자동 업로드 진단을 실행할까요?", isPresented: $showAutomaticUploadValidation) {
            Button("취소", role: .cancel) {}
            Button("검증 실행") { runAutomaticUploadValidation() }
        } message: {
            Text("검사 전용 메모장에 검증 노트를 만들고 본문·첨부·수정·태그·응답 유실 복구를 검사합니다. 처음에는 검사 메모장도 생성합니다. 자동 업로드는 항상 활성화됩니다.")
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
        validationStatus = passed ? "검사 완료" : "확인 필요"
        isValidationExpanded = false
    }

    private func restoreValidationReports() {
        editingValidationReport = library.lastNASNoteEditingValidation()
        attachmentValidationReport = library.lastNASNoteAttachmentValidation()
        let uploadReport = library.lastAutomaticUploadValidation()
        automaticUploadMessage = uploadReport.map(automaticResult)
        let outcomes = [editingValidationReport?.passed, attachmentValidationReport?.passed, uploadReport?.passed].compactMap { $0 }
        validationStatus = outcomes.isEmpty ? nil : (outcomes.allSatisfy { $0 } ? "검사 완료" : "확인 필요")
        isValidationExpanded = outcomes.isEmpty
    }

    private func runEditingValidation() {
        guard !isValidatingWrite else { return }
        isValidatingWrite = true
        writeValidationMessage = "수정 저장·재조회 → 이전 버전 저장 시도 → 최신 본문 확인 중…"
        editingValidationReport = nil
        validationStatus = nil
        Task { @MainActor in
            defer { isValidatingWrite = false }
            do {
                let notebook = try await library.ensureNASValidationNotebook()
                let report = try await library.validateNASNoteEditing(notebookID: notebook.id)
                editingValidationReport = report
                writeValidationMessage = report.passed
                    ? "수정·충돌 검사 통과. 첨부파일 왕복 검증은 다음 단계입니다."
                    : "검사를 통과하지 못했습니다. 아래 노트를 NAS에서 확인한 뒤 다시 진행하세요."
                finishValidation(passed: report.passed)
            } catch {
                writeValidationMessage = "검사 중단: \(error.localizedDescription) 검증 노트가 이미 생성되었을 수 있으니 NAS에서 확인한 뒤 다시 진행하세요."
                validationStatus = "검사 오류"
                isValidationExpanded = true
            }
        }
    }

    private func runAttachmentValidation() {
        guard !isValidatingWrite else { return }
        isValidatingWrite = true
        attachmentValidationReport = nil
        writeValidationMessage = "이미지 업로드·다운로드 → Markdown 원문 저장 → 본문·첨부 연결 복원 확인 중…"
        validationStatus = nil
        Task { @MainActor in
            defer { isValidatingWrite = false }
            do {
                let notebook = try await library.ensureNASValidationNotebook()
                let report = try await library.validateNASNoteAttachments(notebookID: notebook.id)
                attachmentValidationReport = report
                writeValidationMessage = report.passed ? "이미지·Markdown 왕복 검사 통과" : "첨부 검사를 통과하지 못했습니다. 아래 결과를 확인하세요."
                finishValidation(passed: report.passed)
            } catch {
                writeValidationMessage = "첨부 검사 중단: \(error.localizedDescription) NAS의 검증 노트를 확인한 뒤 다시 진행하세요."
                validationStatus = "검사 오류"
                isValidationExpanded = true
            }
        }
    }
    private func runAutomaticUploadValidation() {
        guard !isValidatingWrite else { return }
        isValidatingWrite = true; automaticUploadMessage = "생성·수정·응답 유실 복구 검증 중…"
        validationStatus = nil
        Task { @MainActor in
            defer { isValidatingWrite = false }
            do {
                let notebook = try await library.ensureNASValidationNotebook()
                let report = try await library.validateAutomaticUpload(notebookID: notebook.id)
                automaticUploadMessage = automaticResult(report)
                finishValidation(passed: report.passed)
            } catch {
                automaticUploadMessage = "검사 중단: \(error.localizedDescription)"
                validationStatus = "검사 오류"
                isValidationExpanded = true
            }
        }
    }
    private func automaticResult(_ report: AutomaticUploadValidation) -> String {
        "자동 업로드: \(report.passed ? "검증 통과" : "확인 필요") · 생성 \(report.createVerified ? "확인" : "미확인") · 수정 \(report.updateVerified ? "확인" : "미확인") · 중복 없는 복구 \(report.lostResponseRecovered ? "확인" : "미확인")\n노트 ID: \(report.remoteID ?? "미확인")\n\(report.failure ?? "")"
    }
}

private struct NASAttachmentValidationReportView: View {
    let report: NoteAttachmentValidationReport
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("첨부 검사 · " + report.checkedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            Label("이미지 바이트: \(report.imageBytesVerified ? "확인" : "미확인")", systemImage: report.imageBytesVerified ? "checkmark.circle.fill" : "questionmark.circle")
            Label("Markdown 원문 바이트: \(report.sourceBytesVerified ? "확인" : "미확인")", systemImage: report.sourceBytesVerified ? "checkmark.circle.fill" : "questionmark.circle")
            Label("Markdown·이미지 연결 복원: \(report.markdownRestored ? "확인" : "미확인")", systemImage: report.markdownRestored ? "checkmark.circle.fill" : "questionmark.circle")
            Text(report.receipt.title).textSelection(.enabled)
            Text("노트 ID: \(report.receipt.objectID)").textSelection(.enabled).foregroundStyle(.secondary)
            if let failure = report.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
        }.font(.caption)
    }
}

private struct NASValidationReportView: View {
    let report: NoteEditingValidationReport
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(report.checkedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            status("수정 저장·재조회", confirmed: report.updateConfirmed)
            status("이전 버전 저장 거절 (1064)", confirmed: report.conflictRejected)
            status("최신 본문·버전 유지", confirmed: report.latestContentPreserved)
            Text(report.receipt.title).textSelection(.enabled)
            Text("노트 ID: \(report.receipt.objectID)").textSelection(.enabled).foregroundStyle(.secondary)
            if let failure = report.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
        }.font(.caption)
    }
    private func status(_ title: String, confirmed: Bool) -> some View {
        Label("\(title): \(confirmed ? "확인" : "미확인")", systemImage: confirmed ? "checkmark.circle.fill" : "questionmark.circle")
            .foregroundStyle(confirmed ? Color.green : Color.secondary)
    }
}
