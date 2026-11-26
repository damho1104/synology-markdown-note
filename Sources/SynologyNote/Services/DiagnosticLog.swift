import Foundation
import AppKit
import OSLog
import NoteCore

enum DiagnosticEvent: String {
    case databaseMaintenance = "database.maintenance", diagnosticExport = "diagnostic.export"
    case appStarted = "app.started", appTerminating = "app.terminating"
    case inspectorRequested = "inspector.requested", inspectorOpened = "inspector.opened", inspectorClosed = "inspector.closed"
    case connectionStarted = "connection.started", connectionSucceeded = "connection.succeeded", connectionFailed = "connection.failed", disconnected = "connection.disconnected", recoveryStarted = "connection.recovery"
    case noteCreated = "note.created", noteSaved = "note.saved", noteSaveFailed = "note.save_failed", imported = "note.imported"
    case noteDeleteRequested = "note.delete_requested", noteDeleted = "note.deleted", noteDeleteFailed = "note.delete_failed", noteDeleteCacheFailed = "note.delete_cache_failed"
    case refreshCompleted = "refresh.completed", refreshFailed = "refresh.failed"
    case uploadStarted = "upload.started", uploadCompleted = "upload.completed", uploadPending = "upload.pending", uploadFailed = "upload.failed"
    case notebookCreated = "notebook.created", notebookRenamed = "notebook.renamed", notebookMigrating = "notebook.migrating", notebookMigrated = "notebook.migrated"
    case notebookDeleteRequested = "notebook.delete_requested", notebookDeleted = "notebook.deleted", notebookDeleteFailed = "notebook.delete_failed"
    case stackMutationStarted = "stack.mutation_started", stackMutationCompleted = "stack.mutation_completed", stackMutationFailed = "stack.mutation_failed"
}

/// Bounded local JSONL diagnostics plus unified logging. Only allowlisted
/// metadata is serialized; never serialize Error descriptions or user payloads.
final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    let directory: URL
    private var policy: DiagnosticLogPolicy
    private let logger = Logger(subsystem: "com.damho.SynologyMarkdown", category: "Diagnostics")
    private let formatter = ISO8601DateFormatter()
    private let allowedFields: Set<String> = ["account", "note_id", "notebook_id", "revision", "count", "pending", "attempts", "state", "automatic", "visible", "error_kind", "error_code", "operation", "phase", "duration_ms", "bytes", "free_pages", "fts_rows", "document_rows", "backup_count"]
    private var lastWriteError: String?
    var writeError: String? {
        lock.lock(); defer { lock.unlock() }
        return lastWriteError
    }

    convenience init(root: URL, maximumBytes: Int = 2 * 1024 * 1024, backups: Int = 3) {
        let files = min(max(0, backups), 19) + 1
        let bytes = min(max(1, maximumBytes), 10 * DiagnosticLogPolicy.mebibyte)
        self.init(root: root, policy: DiagnosticLogPolicy(maximumFileBytes: bytes, maximumFiles: files,
                                                        maximumTotalBytes: bytes * files))
    }

    init(root: URL, policy: DiagnosticLogPolicy) {
        directory = root.appendingPathComponent("logs")
        self.policy = policy
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        updatePolicy(policy)
    }

    func updatePolicy(_ policy: DiagnosticLogPolicy) {
        lock.lock(); defer { lock.unlock() }
        self.policy = policy
        do { try enforceLimits(); lastWriteError = nil }
        catch { lastWriteError = appText("Could not apply log retention limits. Check available disk space and folder permissions.") }
    }

    func rotateNow() {
        lock.lock(); defer { lock.unlock() }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let current = directory.appendingPathComponent("app.jsonl")
            if manager.fileExists(atPath: current.path) {
                guard try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
                try rotateCurrent()
            }
            try enforceLimits(reserving: 1)
            guard manager.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            lastWriteError = nil
        } catch { lastWriteError = appText("Could not rotate the log. Check available disk space and folder permissions.") }
    }

    private func ownedLogs() throws -> [(index: Int, url: URL)] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).compactMap { url in
            guard let index = Self.rotationIndex(for: url.lastPathComponent) else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (index, url)
        }.sorted { $0.index < $1.index }
    }

    private func size(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Retain only complete recent lines when a file exceeds a lowered limit.
    private func trim(_ url: URL) throws {
        let bytes = try size(url)
        guard bytes > policy.effectiveFileBytes else { return }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(bytes - policy.effectiveFileBytes))
        let tail = try file.readToEnd() ?? Data()
        let boundary = tail.firstIndex(of: 0x0a)
        let complete = boundary.map { Data(tail[tail.index(after: $0)...]) } ?? Data()
        try complete.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Reserve space and a file slot before a new event is written.
    private func enforceLimits(reserving incoming: Int = 0) throws {
        let manager = FileManager.default
        var files = try ownedLogs()
        for file in files { try trim(file.url) }
        let slots = policy.maximumFiles - (incoming > 0 && !files.contains(where: { $0.index == 0 }) ? 1 : 0)
        for file in files.dropFirst(slots) { try manager.removeItem(at: file.url) }
        files = Array(files.prefix(slots))
        var total = try files.reduce(0) { try $0 + size($1.url) }
        for file in files.reversed() where total + incoming > policy.maximumTotalBytes {
            let bytes = try size(file.url)
            try manager.removeItem(at: file.url)
            total -= bytes
        }
    }

    private func rotateCurrent() throws {
        let manager = FileManager.default
        for file in try ownedLogs().reversed() {
            if file.index >= policy.maximumFiles - 1 {
                try manager.removeItem(at: file.url)
            } else {
                try manager.moveItem(at: file.url, to: directory.appendingPathComponent("app.\(file.index + 1).jsonl"))
            }
        }
    }

    func record(_ event: DiagnosticEvent, fields: [String: String] = [:], error: Error? = nil) {
        lock.lock(); defer { lock.unlock() }
        var metadata = fields.filter { allowedFields.contains($0.key) }.mapValues { String($0.prefix(256)) }
        if let error { metadata.merge(Self.errorMetadata(error)) { _, new in new } }
        let entry: [String: Any] = ["time": formatter.string(from: Date()), "event": event.rawValue,
            "version": AppVersion.display ?? "development",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            "pid": ProcessInfo.processInfo.processIdentifier, "fields": metadata]
        if error != nil || metadata["phase"] == "failed" { logger.error("\(event.rawValue, privacy: .public) \(metadata.description, privacy: .private)") }
        else { logger.info("\(event.rawValue, privacy: .public) \(metadata.description, privacy: .private)") }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let current = directory.appendingPathComponent("app.jsonl")
            var bytes = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            bytes.append(0x0a)
            guard bytes.count <= policy.effectiveFileBytes else {
                lastWriteError = appText("A log entry exceeded the file size limit and was skipped.")
                logger.error("diagnostic_entry_exceeds_limit")
                return
            }
            if manager.fileExists(atPath: current.path) {
                guard try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if try size(current) + bytes.count > policy.effectiveFileBytes { try rotateCurrent() }
            }
            try enforceLimits(reserving: bytes.count)
            if !manager.fileExists(atPath: current.path) { manager.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let file = try FileHandle(forWritingTo: current)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: bytes)
            lastWriteError = nil
        } catch {
            lastWriteError = appText("Could not write the log file. Check available disk space and folder permissions.")
            logger.error("diagnostic_file_write_failed")
        }
    }

    func maintenanceObserver(account: String) -> DatabaseMaintenance.Observer {
        { [self] event in
            var fields = event.metrics.mapValues(String.init)
            fields["account"] = String(account.prefix(12))
            fields["operation"] = event.operation.rawValue
            fields["phase"] = event.phase.rawValue
            record(.databaseMaintenance, fields: fields)
        }
    }

    /// Capture all rotations under the same lock used for writes and rotation.
    func logFiles() throws -> [(String, Data)] {
        lock.lock(); defer { lock.unlock() }
        return try ownedLogs().prefix(policy.maximumFiles).map { ($0.url.lastPathComponent, try Data(contentsOf: $0.url)) }
    }

    static func errorMetadata(_ error: Error) -> [String: String] {
        if let failure = error as? NoteStationError {
            let kind: String
            switch failure {
            case .api(let code): return ["error_kind": "api", "error_code": String(code)]
            case .transport(let code): return ["error_kind": "transport", "error_code": String(code)]
            case .http(let code): return ["error_kind": "http", "error_code": String(code)]
            case .authenticationFailed(let code): return ["error_kind": "authentication", "error_code": String(code)]
            case .invalidArgument: kind = "invalid_argument"
            case .unsupportedAPI: kind = "unsupported_api"
            case .notebookWriteUncertain: kind = "notebook_write_uncertain"
            case .stackWriteUncertain: kind = "stack_write_uncertain"
            case .invalidBaseURL: kind = "invalid_base_url"
            case .insecureTransport: kind = "insecure_transport"
            case .notConnected: kind = "not_connected"
            case .connectionChanged: kind = "connection_changed"
            case .otpRequired: kind = "otp_required"
            case .invalidOTP: kind = "invalid_otp"
            case .sessionExpired: kind = "session_expired"
            case .permissionDenied: kind = "permission_denied"
            case .lockedNote: kind = "locked_note"
            case .cancelled: kind = "cancelled"
            case .invalidResponse: kind = "invalid_response"
            case .writeContractUnvalidated: kind = "write_unavailable"
            case .versionConflict: kind = "version_conflict"
            case .validationInProgress: kind = "validation_in_progress"
            }
            return ["error_kind": kind]
        }
        if let url = error as? URLError { return ["error_kind": "transport", "error_code": String(url.code.rawValue)] }
        if error is RepositoryError { return ["error_kind": "repository"] }
        if let sync = error as? SyncError {
            switch sync {
            case .verificationFailed: return ["error_kind": "readback_verification"]
            case .uncertain: return ["error_kind": "write_uncertain"]
            case .remoteChanged: return ["error_kind": "remote_changed"]
            case .invalidBlocks: return ["error_kind": "invalid_blocks"]
            }
        }
        if error is CancellationError { return ["error_kind": "cancelled"] }
        return ["error_kind": "internal", "error_code": String((error as NSError).code)]
    }
}

extension LibraryStore {
    func logEvent(_ event: DiagnosticEvent, noteID: UUID? = nil, notebookID: String? = nil, fields: [String: String] = [:], error: Error? = nil) {
        if diagnosticLog == nil { diagnosticLog = DiagnosticLog(root: root, policy: diagnosticLogPolicy) }
        var metadata = fields
        if metadata["account"] == nil { metadata["account"] = String(profile.storageKey.prefix(12)) }
        if let noteID { metadata["note_id"] = noteID.uuidString }
        if let notebookID { metadata["notebook_id"] = notebookID }
        diagnosticLog?.record(event, fields: metadata, error: error)
    }
    func updateDiagnosticLogPolicy(_ policy: DiagnosticLogPolicy) {
        diagnosticLogPolicy = policy
        policy.persist(to: preferences)
        if diagnosticLog == nil { diagnosticLog = DiagnosticLog(root: root, policy: policy) }
        else { diagnosticLog?.updatePolicy(policy) }
    }
    var logDirectory: URL { root.appendingPathComponent("logs") }
    func openLogDirectory() {
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(logDirectory)
        } catch { errorMessage = appText("Could not open the log folder: ") + error.localizedDescription }
    }
}
