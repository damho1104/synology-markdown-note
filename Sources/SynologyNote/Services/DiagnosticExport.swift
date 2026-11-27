import Foundation
import AppKit
import UniformTypeIdentifiers
import NoteCore

enum DiagnosticExport {
    /// Reconstruct entries from a strict value allowlist. Never copy raw log lines.
    struct Sanitizer {
        private var identities: [String: String] = [:]
        private let numericFields: Set<String> = ["revision", "count", "pending", "attempts", "error_code", "duration_ms", "bytes", "free_pages", "fts_rows", "document_rows", "backup_count"]
        private let states: Set<String> = ["local", "synced", "failed", "conflict", "uncertain", "pending", "sending", "create", "rename", "rename.waiting", "rename.nas", "rename.local", "delete", "move", "add", "remove"]
        private let errorKinds: Set<String> = ["api", "transport", "http", "authentication", "invalid_argument", "unsupported_api", "notebook_write_uncertain", "stack_write_uncertain", "invalid_base_url", "insecure_transport", "not_connected", "connection_changed", "otp_required", "invalid_otp", "session_expired", "permission_denied", "locked_note", "cancelled", "invalid_response", "write_unavailable", "version_conflict", "validation_in_progress", "repository", "readback_verification", "write_uncertain", "remote_changed", "invalid_blocks", "internal"]

        mutating func clean(_ bytes: Data) throws -> (data: Data, omitted: Int) {
            var output = Data(), omitted = 0
            let dates = ISO8601DateFormatter()
            dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for line in bytes.split(separator: 0x0a) {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let event = entry["event"] as? String, DiagnosticEvent(rawValue: event) != nil,
                      let time = entry["time"] as? String, let date = dates.date(from: time) else {
                    omitted += 1; continue
                }
                var fields: [String: String] = [:]
                for (key, value) in entry["fields"] as? [String: String] ?? [:] {
                    if ["account", "note_id", "notebook_id"].contains(key) {
                        let identity = key + ":" + value
                        if identities[identity] == nil { identities[identity] = "item-\(identities.count + 1)" }
                        fields[key] = identities[identity]
                    } else if numericFields.contains(key), Self.matches(value, "^-?[0-9]{1,20}$") {
                        fields[key] = value
                    } else if ["automatic", "visible"].contains(key), ["true", "false"].contains(value) {
                        fields[key] = value
                    } else if key == "state", states.contains(value) {
                        fields[key] = value
                    } else if key == "error_kind", errorKinds.contains(value) {
                        fields[key] = value
                    } else if key == "operation", DatabaseMaintenanceEvent.Operation(rawValue: value) != nil {
                        fields[key] = value
                    } else if key == "phase", DatabaseMaintenanceEvent.Phase(rawValue: value) != nil {
                        fields[key] = value
                    }
                }
                var clean: [String: Any] = ["time": dates.string(from: date), "event": event, "fields": fields]
                if let version = entry["version"] as? String, Self.safeVersion(version) { clean["version"] = version }
                if let build = entry["build"] as? String, Self.matches(build, "^[0-9]{1,10}$") { clean["build"] = build }
                output.append(try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]))
                output.append(0x0a)
            }
            return (output, omitted)
        }

        static func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) != nil
        }
        static func safeVersion(_ value: String) -> Bool {
            value == "development" || matches(value, "^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9a-f]{7,40})?$")
        }
    }

    static func archive(report: DatabaseDiagnosticReport?, logFiles: [(String, Data)],
                        version: String?, destination: URL) throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("synology-diagnostics-\(UUID().uuidString)")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        let payload = temporary.appendingPathComponent("diagnostics")
        let logs = payload.appendingPathComponent("logs")
        try manager.createDirectory(at: logs, withIntermediateDirectories: true)
        var sanitizer = Sanitizer(), omitted = 0, files = 0
        for (name, data) in logFiles where DiagnosticLog.rotationIndex(for: name) != nil {
            let clean = try sanitizer.clean(data)
            try clean.data.write(to: logs.appendingPathComponent(name))
            omitted += clean.omitted; files += 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let report { try encoder.encode(report).write(to: payload.appendingPathComponent("database-summary.json")) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let manifest: [String: Any] = [
            "format_version": 1, "created_at": ISO8601DateFormatter().string(from: Date()),
            "app_version": version.flatMap { Sanitizer.safeVersion($0) ? $0 : nil } ?? "development",
            "os_version": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "includes_database_summary": report != nil, "log_files": files, "omitted_log_lines": omitted,
            "contains_raw_database": false, "contains_attachments": false,
            "identifiers": "per-export aliases; mapping is not included"
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: payload.appendingPathComponent("manifest.json"))
        try appText("diagnostics.readme").write(to: payload.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let zip = temporary.appendingPathComponent("diagnostics.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noacl", "--noqtn", payload.path, zip.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RepositoryError(message: appText("Could not create the diagnostic ZIP.")) }
        // Atomic publication also preserves an existing destination on write failure.
        try Data(contentsOf: zip).write(to: destination, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

extension LibraryStore {
    func exportDiagnostics(to destination: URL, includeDatabase: Bool) async throws {
        let repo = repository
        let log = diagnosticLog ?? DiagnosticLog(root: root, policy: diagnosticLogPolicy)
        diagnosticLog = log
        log.record(.diagnosticExport, fields: ["phase": "started"])
        do {
            let report = includeDatabase ? try await repo.diagnosticReport() : nil
            let files = try log.logFiles()
            let version = AppVersion.display
            try await Task.detached(priority: .utility) {
                try DiagnosticExport.archive(report: report, logFiles: files, version: version, destination: destination)
            }.value
            log.record(.diagnosticExport, fields: ["phase": "completed"])
        } catch {
            log.record(.diagnosticExport, fields: ["phase": "failed"], error: error)
            throw error
        }
    }
}
