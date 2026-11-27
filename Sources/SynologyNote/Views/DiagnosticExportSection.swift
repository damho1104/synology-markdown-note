import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiagnosticExportSection: View {
    @Environment(LibraryStore.self) private var library
    @State private var exporting = false
    @State private var message: String?
    @State private var exportedURL: URL?

    var body: some View {
        Section(appText("Export")) {
            HStack {
                Button(appText("Export Diagnostics…")) { export(includeDatabase: true) }
                Button(appText("Export Logs Only…")) { export(includeDatabase: false) }
                if exporting { ProgressView().controlSize(.small) }
            }
            .disabled(exporting)
            Text(appText("Diagnostics include database status, integrity check results, and current and previous logs. You can also export just the logs."))
                .font(.caption).foregroundStyle(.secondary)
            Text(appText("Note titles, bodies, revision content, attachments, sign-in details, and the original database are excluded. Account, note, and notebook identifiers are anonymized. Timestamps and error codes are included."))
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            if let exportedURL {
                Button(appText("Show Exported File")) { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
            }
        }
    }

    private func export(includeDatabase: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = includeDatabase ? "SynologyNote-diagnostics.zip" : "SynologyNote-logs.zip"
        panel.message = includeDatabase
            ? appText("Save a database status report without personal data and anonymized logs.")
            : appText("Save anonymized current and previous logs.")
        exporting = true; message = nil; exportedURL = nil
        panel.begin { response in
            Task { @MainActor in
                defer { exporting = false }
                guard response == .OK, let url = panel.url else { return }
                do {
                    try await library.exportDiagnostics(to: url, includeDatabase: includeDatabase)
                    exportedURL = url
                    message = appText("The diagnostic ZIP was saved.")
                } catch {
                    message = appText("Could not export. Check the destination and available disk space, then try again.")
                }
            }
        }
    }
}
