import SwiftUI

struct DiagnosticLogSettingsSection: View {
    @Environment(LibraryStore.self) private var library
    @State private var rotationMessage: String?

    var body: some View {
        Section(appText("Log Rotation and Retention")) {
            Picker(appText("Maximum Size per File"), selection: binding(\.maximumFileBytes)) {
                ForEach(DiagnosticLogPolicy.fileSizesMiB, id: \.self) { size in
                    Text("\(size) MiB").tag(size * DiagnosticLogPolicy.mebibyte)
                }
            }
            Stepper(value: binding(\.maximumFiles), in: 1...20) {
                Text(appText("Maximum files to keep: %@ (including the current file)", AppLocalization.number(library.diagnosticLogPolicy.maximumFiles)))
            }
            Picker(appText("Maximum Total Log Size"), selection: binding(\.maximumTotalBytes)) {
                ForEach(DiagnosticLogPolicy.totalSizesMiB, id: \.self) { size in
                    Text("\(size) MiB").tag(size * DiagnosticLogPolicy.mebibyte)
                }
            }
            Text(appText("The oldest logs are removed first when a size or count limit is reached. The total limit takes precedence if it is smaller than the per-file limit. Lower limits apply immediately to existing logs."))
                .font(.caption).foregroundStyle(.secondary)
            Button(appText("Rotate Logs Now")) {
                library.diagnosticLog?.rotateNow()
                rotationMessage = library.diagnosticLog?.writeError ?? appText("A new log file is ready.")
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
