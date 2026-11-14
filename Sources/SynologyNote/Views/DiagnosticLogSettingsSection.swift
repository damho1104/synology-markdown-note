import SwiftUI

struct DiagnosticLogSettingsSection: View {
    @Environment(LibraryStore.self) private var library
    @State private var rotationMessage: String?

    var body: some View {
        Section("로그 회전·보관") {
            Picker("파일당 최대 용량", selection: binding(\.maximumFileBytes)) {
                ForEach(DiagnosticLogPolicy.fileSizesMiB, id: \.self) { size in
                    Text("\(size) MiB").tag(size * DiagnosticLogPolicy.mebibyte)
                }
            }
            Stepper(value: binding(\.maximumFiles), in: 1...20) {
                Text("최대 보관 파일 수: \(library.diagnosticLogPolicy.maximumFiles)개 (현재 파일 포함)")
            }
            Picker("전체 로그 최대 용량", selection: binding(\.maximumTotalBytes)) {
                ForEach(DiagnosticLogPolicy.totalSizesMiB, id: \.self) { size in
                    Text("\(size) MiB").tag(size * DiagnosticLogPolicy.mebibyte)
                }
            }
            Text("용량이나 개수 한도에 도달하면 오래된 로그부터 정리합니다. 전체 용량이 파일당 한도보다 작으면 전체 한도를 우선 적용합니다. 한도를 낮추면 기존 로그에도 즉시 적용됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            Button("지금 로그 회전") {
                library.diagnosticLog?.rotateNow()
                rotationMessage = library.diagnosticLog?.writeError ?? "새 로그 파일을 준비했습니다."
            }
            if let rotationMessage { Text(rotationMessage).font(.caption) }
            if let error = library.diagnosticLog?.writeError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func binding(_ key: KeyPath<DiagnosticLogPolicy, Int>) -> Binding<Int> {
        Binding(get: { library.diagnosticLogPolicy[keyPath: key] }, set: { value in
            let old = library.diagnosticLogPolicy
            library.updateDiagnosticLogPolicy(DiagnosticLogPolicy(
                maximumFileBytes: key == \DiagnosticLogPolicy.maximumFileBytes ? value : old.maximumFileBytes,
                maximumFiles: key == \DiagnosticLogPolicy.maximumFiles ? value : old.maximumFiles,
                maximumTotalBytes: key == \DiagnosticLogPolicy.maximumTotalBytes ? value : old.maximumTotalBytes))
            rotationMessage = nil
        })
    }
}
