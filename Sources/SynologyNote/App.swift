import SwiftUI
import Observation
import NoteCore

enum AppVersion {
    static var display: String? {
        Bundle.main.object(forInfoDictionaryKey: "SynologyDisplayVersion") as? String
    }
}

@main
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
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
        .defaultSize(width: 1360, height: 880)
        .commands {
            NoteCommands()
            CommandGroup(replacing: .appInfo) {
                Button("Synology Markdown Note 정보") {
                    if let version = AppVersion.display {
                        NSApp.orderFrontStandardAboutPanel(options: [.version: version])
                    } else {
                        NSApp.orderFrontStandardAboutPanel(nil)
                    }
                }
            }
        }
        Settings {
            if let library = launch.library { SettingsView().environment(library) }
            else { ContentUnavailableView("로컬 저장소 복구 필요", systemImage: "externaldrive.badge.exclamationmark", description: Text("기본 창에서 데이터베이스를 복구한 다음 설정을 사용하세요.")) }
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
        let defaults = ProcessInfo.processInfo.environment["SYNOLOGY_NOTE_DATA_DIR"] == nil
            ? UserDefaults.standard
            : UserDefaults(suiteName: "com.damho.SynologyMarkdown.verify." + root.lastPathComponent) ?? .standard
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
                failure = "복구본을 열지 못했고 원본 파일 복원도 실패했습니다: \(error.localizedDescription). recovery 폴더를 확인하세요."
                throw RepositoryError(message: failure)
            }
            failure = error.localizedDescription
            throw RepositoryError(message: "복구본을 열지 못해 원본 DB를 되돌렸습니다: \(initialError.localizedDescription)")
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
                alert.messageText = "일부 변경을 저장하지 못했습니다"
                alert.informativeText = "저장 오류를 확인한 다음 다시 종료하세요."
                alert.addButton(withTitle: "돌아가기")
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: !failed)
        }
        return .terminateLater
    }
}
