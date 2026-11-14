import SwiftUI
import AppKit
import NoteCore

/// Shown instead of the editor when the account's SQLite file cannot be opened.
struct DatabaseRecoveryView: View {
    let directory: URL
    let failure: String
    let restore: (URL) throws -> Void

    @State private var selected: URL?
    @State private var confirming = false
    @State private var recoveryError: String?

    private var snapshots: [DatabaseMaintenance.Snapshot] { DatabaseMaintenance.snapshots(in: directory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("로컬 데이터베이스를 열 수 없습니다", systemImage: "externaldrive.badge.exclamationmark")
                .font(.title2.bold())
            Text(failure)
                .foregroundStyle(.secondary)
            Text("노트와 동기화 대기 작업을 보호하기 위해 저장소를 자동 초기화하지 않았습니다. 아래 백업에서 복구할 수 있습니다.")
            if snapshots.isEmpty {
                ContentUnavailableView("복구할 자동 백업이 없습니다", systemImage: "clock.arrow.circlepath", description: Text("원본 DB와 첨부파일은 그대로 있습니다. 저장소 폴더를 보존하고 문제를 확인해 주세요."))
            } else {
                Text("이 계정의 자동 백업").font(.headline)
                List(snapshots, selection: $selected) { item in
                    HStack {
                        Image(systemName: "externaldrive")
                        Text(item.date, format: .dateTime.year().month().day().hour().minute())
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    .tag(item.url)
                }
                .frame(height: 220)
            }
            if let recoveryError {
                Text(recoveryError).foregroundStyle(.red)
            }
            HStack {
                Button("저장소 폴더 보기") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
                }
                Spacer()
                Button("선택한 백업으로 복구…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil)
            }
        }
        .padding(28)
        .frame(maxWidth: 660)
        .onAppear { selected = snapshots.first?.url }
        .alert("백업으로 복구하시겠습니까?", isPresented: $confirming) {
            Button("취소", role: .cancel) {}
            Button("백업 복구", role: .destructive) {
                guard let selected else { return }
                do { try restore(selected) }
                catch { recoveryError = error.localizedDescription }
            }
        } message: {
            Text("백업 시점 이후의 로컬 편집 및 NAS 전송 대기 내용은 복구본에 없을 수 있습니다. 현재 DB와 WAL 파일은 recovery 폴더에 보존되며, 첨부파일은 삭제하지 않습니다.")
        }
    }
}
