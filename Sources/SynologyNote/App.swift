import SwiftUI
import Observation
import NoteCore

enum AppVersion {
    static var display: String? {
        Bundle.main.object(forInfoDictionaryKey: "SynologyDisplayVersion") as? String
    }
}

@main
enum SynologyNoteMain {
    @MainActor static func main() {
        AppLocalization.applyProcessLanguagePreference()
        SynologyNoteApp.main()
    }
}

struct SynologyNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var launch = LibraryLaunchState()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup("Synology Markdown Note") {
            Group {
                if let library = launch.library {
                    LibraryView().environment(library)
                        .onAppear { delegate.library = library }
                } else {
                    DatabaseRecoveryView(directory: launch.directory, failure: launch.failure) { snapshot in
                        try launch.restore(snapshot)
                    }
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .environment(\.locale, AppLocalization.locale)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
        .defaultSize(width: 1360, height: 880)
        .commands {
            NoteCommands()
            CommandGroup(replacing: .appInfo) {
                Button(appText("About Synology Markdown Note")) {
                    if let version = AppVersion.display {
                        NSApp.orderFrontStandardAboutPanel(options: [.version: version])
                    } else {
                        NSApp.orderFrontStandardAboutPanel(nil)
                    }
                }
            }
        }
        Settings {
            if let library = launch.library { SettingsView().environment(library).environment(\.locale, AppLocalization.locale) }
            else { ContentUnavailableView(appText("Local Storage Recovery Required"), systemImage: "externaldrive.badge.exclamationmark", description: Text(appText("Recover the database in the main window to use Settings."))) }
        }
    }
}

@MainActor @Observable
final class LibraryLaunchState {
    private(set) var library: LibraryStore?
    private(set) var failure = ""
    let directory: URL
    private let recoveryLog: DiagnosticLog

    init() {
        let root = LibraryStore.storageRoot()
        let defaults = NoteLocalization.preferences
        recoveryLog = DiagnosticLog(root: root, policy: DiagnosticLogPolicy.load(from: defaults))
        directory = root.appendingPathComponent(ConnectionProfile.load(from: defaults).storageKey)
        do { library = try LibraryStore() }
        catch { failure = error.localizedDescription }
    }

    func restore(_ backup: URL) throws {
        // Only reachable when there is no open NoteRepository. Never replace a
        // live database connection or start NAS synchronization during restore.
        let observer = recoveryLog.maintenanceObserver(account: directory.lastPathComponent)
        let quarantine = try DatabaseMaintenance.restore(backup, in: directory, observer: observer)
        do {
            library = try LibraryStore()
            failure = ""
        } catch {
            let initialError = error
            do { try DatabaseMaintenance.rollbackRestore(in: directory, from: quarantine, observer: observer) }
            catch {
                failure = appText("Could not open the recovered copy or restore the original files: %@. Check the recovery folder.", "\(error.localizedDescription)")
                throw RepositoryError(message: failure)
            }
            failure = error.localizedDescription
            throw RepositoryError(message: appText("Could not open the recovered copy. The original database was restored: %@", "\(initialError.localizedDescription)"))
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var library: LibraryStore?
    private var terminationSignal: DispatchSourceSignal?
    private var signalTerminationInProgress = false
    private var allowImmediateTermination = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, !self.signalTerminationInProgress else { return }
                self.signalTerminationInProgress = true
                if let library = self.library {
                    await library.flush()
                    if library.sessions.values.contains(where: { $0.saveError != nil }) {
                        self.signalTerminationInProgress = false
                        return
                    }
                }
                self.allowImmediateTermination = true
                NSApp.terminate(nil)
            }
        }
        source.resume()
        terminationSignal = source
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        library?.logEvent(.appTerminating)
        if allowImmediateTermination { return .terminateNow }
        guard let library else { return .terminateNow }
        Task {
            await library.flush()
            let failed = library.sessions.values.contains(where: { $0.saveError != nil })
            if failed {
                let alert = NSAlert()
                alert.messageText = appText("Some Changes Could Not Be Saved")
                alert.informativeText = appText("Check the save errors and try quitting again.")
                alert.addButton(withTitle: appText("Go Back"))
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: !failed)
        }
        return .terminateLater
    }
}
