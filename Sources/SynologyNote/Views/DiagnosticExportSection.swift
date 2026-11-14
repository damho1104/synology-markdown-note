import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiagnosticExportSection: View {
    @Environment(LibraryStore.self) private var library
    @State private var exporting = false
    @State private var message: String?
    @State private var exportedURL: URL?

    var body: some View {
        Section("내보내기") {
            HStack {
                Button("진단 자료 내보내기…") { export(includeDatabase: true) }
                Button("로그만 내보내기…") { export(includeDatabase: false) }
                if exporting { ProgressView().controlSize(.small) }
            }
            .disabled(exporting)
            Text("진단 자료에는 DB 상태·무결성 검사 결과와 현재·이전 로그가 포함됩니다. 로그만 내보낼 수도 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("노트 제목·본문·수정 이력 내용·첨부파일·로그인 정보·원본 DB는 제외합니다. 계정·노트·메모장 식별자는 익명화하며, 작업 시각과 오류 코드는 포함합니다.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            if let exportedURL {
                Button("내보낸 파일 보기") { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
            }
        }
    }

    private func export(includeDatabase: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = includeDatabase ? "SynologyNote-diagnostics.zip" : "SynologyNote-logs.zip"
        panel.message = includeDatabase
            ? "개인정보를 제외한 DB 상태 보고서와 익명화한 로그를 저장합니다."
            : "현재 및 이전 로그를 익명화하여 저장합니다."
        exporting = true; message = nil; exportedURL = nil
        panel.begin { response in
            Task { @MainActor in
                defer { exporting = false }
                guard response == .OK, let url = panel.url else { return }
                do {
                    try await library.exportDiagnostics(to: url, includeDatabase: includeDatabase)
                    exportedURL = url
                    message = "진단 ZIP을 저장했습니다."
                } catch {
                    message = "내보내지 못했습니다. 저장 위치와 여유 공간을 확인한 뒤 다시 시도하세요."
                }
            }
        }
    }
}
