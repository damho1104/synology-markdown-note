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
            Label(appText("Could Not Open the Local Database"), systemImage: "externaldrive.badge.exclamationmark")
                .font(.title2.bold())
            Text(failure)
                .foregroundStyle(.secondary)
            Text(appText("To protect your notes and pending changes, the app kept the existing storage. You can recover it from a backup below."))
            if snapshots.isEmpty {
                ContentUnavailableView(appText("No Automatic Backups Available"), systemImage: "clock.arrow.circlepath", description: Text(appText("The original database and attachments are still in place. Keep the storage folder while you investigate.")))
            } else {
                Text(appText("Automatic Backups for This Account")).font(.headline)
                List(snapshots, selection: $selected) { item in
                    HStack {
                        Image(systemName: "externaldrive")
                        Text(item.date, format: .dateTime.year().month().day().hour().minute().locale(AppLocalization.locale))
                        Spacer()
                        Text(item.size.formatted(.byteCount(style: .file).locale(AppLocalization.locale)))
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
                Button(appText("Show Storage Folder")) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
                }
                Spacer()
                Button(appText("Restore from Selected Backup…")) { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil)
            }
        }
        .padding(28)
        .frame(maxWidth: 660)
        .onAppear { selected = snapshots.first?.url }
        .alert(appText("Restore from Backup?"), isPresented: $confirming) {
            Button(appText("Cancel"), role: .cancel) {}
            Button(appText("Restore Backup"), role: .destructive) {
                guard let selected else { return }
                do { try restore(selected) }
                catch { recoveryError = error.localizedDescription }
            }
        } message: {
            Text(appText("Local edits and pending uploads made after the backup may be missing from the restored copy. The current database and WAL files are kept in the recovery folder, and attachments are kept."))
        }
    }
}
