import Foundation
import Testing
import NoteCore
@testable import SynologyNote

@Suite @MainActor struct DiagnosticExportTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func reconstructsLogsWithoutSecretsEvenInPreviouslyAllowedFields() throws {
        let entry: [String: Any] = [
            "time": "2026-11-07T10:00:00.000Z", "event": "upload.failed",
            "version": "SECRET-VERSION", "build": "SECRET-BUILD", "secret": "SECRET-TOP",
            "fields": ["account": "SECRET-ACCOUNT", "note_id": "SECRET-NOTE", "notebook_id": "SECRET-NOTEBOOK",
                       "state": "SECRET-STATE", "error_kind": "SECRET-KIND", "error_code": "SECRET-CODE",
                       "count": "SECRET-COUNT", "password": "SECRET-PASSWORD", "body": "SECRET-BODY"]
        ]
        var raw = try JSONSerialization.data(withJSONObject: entry)
        raw.append(0x0a); raw.append(Data("SECRET-MALFORMED\n".utf8))
        var sanitizer = DiagnosticExport.Sanitizer()
        let first = try sanitizer.clean(raw)
        let second = try sanitizer.clean(try JSONSerialization.data(withJSONObject: entry))
        let text = String(decoding: first.data, as: UTF8.self)
        #expect(!text.contains("SECRET"))
        #expect(first.omitted == 1)
        #expect(first.data == second.data)
        let clean = try #require(JSONSerialization.jsonObject(with: first.data) as? [String: Any])
        let fields = try #require(clean["fields"] as? [String: String])
        #expect(fields.count == 3)
        #expect(Set(fields.values).count == 3)
    }

    @Test func exportsRealZIPWithAggregateDatabaseAndAllLogRotationsOnly() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "diagnostic-export-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = try LibraryStore(root: folder, profile: ConnectionProfile(), preferences: preferences)
        let note = try await store.repository.save(NoteRecord(title: "SECRET-TITLE", markdown: "SECRET-BODY"))
        _ = try await store.repository.backupIfNeeded(force: true)
        let log = try #require(store.diagnosticLog)
        log.record(.noteSaved, fields: ["note_id": note.id.uuidString, "count": "1"])
        let original = try Data(contentsOf: log.directory.appendingPathComponent("app.jsonl"))
        for i in 1...3 { try original.write(to: log.directory.appendingPathComponent("app.\(i).jsonl")) }
        // An unrelated file in the log folder must never be included.
        try Data("SECRET-EXTRA".utf8).write(to: log.directory.appendingPathComponent("credentials.json"))
        let zip = folder.appendingPathComponent("diagnostics.zip")
        try await store.exportDiagnostics(to: zip, includeDatabase: true)
        let listing = Process(), pipe = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-Z", "-1", zip.path]
        listing.standardOutput = pipe
        try listing.run()
        let archiveNames = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        listing.waitUntilExit()
        #expect(listing.terminationStatus == 0)
        #expect(!archiveNames.contains("._") && !archiveNames.contains("__MACOSX"))
        let unpacked = try unpack(zip, in: folder.appendingPathComponent("full"))
        let names = try FileManager.default.subpathsOfDirectory(atPath: unpacked.path)
        #expect(Set(names) == ["README.txt", "manifest.json", "database-summary.json", "logs", "logs/app.jsonl", "logs/app.1.jsonl", "logs/app.2.jsonl", "logs/app.3.jsonl"])
        for name in names where name != "logs" {
            let text = try String(contentsOf: unpacked.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains("SECRET"))
            #expect(!text.contains(note.id.uuidString))
            #expect(!text.contains(folder.path))
        }
        let report = try JSONDecoder().decode(DatabaseDiagnosticReport.self, from: Data(contentsOf: unpacked.appendingPathComponent("database-summary.json")))
        #expect(report.integrityOK)
        #expect(report.tableCounts["notes"] == 1 && report.tableCounts["revisions"] == 1)
        #expect(report.tableCounts["operations"] == 1)
        #expect(report.orphanedSearchRows == 0 && report.backupCount == 1)
        #expect(try await store.repository.note(id: note.id)?.markdown == "SECRET-BODY")
        let logs = try String(contentsOf: unpacked.appendingPathComponent("logs/app.jsonl"), encoding: .utf8)
        #expect(logs.contains("database.maintenance") && logs.contains("backup"))
        #expect(logs.contains("duration_ms"))

        let logsZip = folder.appendingPathComponent("logs-only.zip")
        try await store.exportDiagnostics(to: logsZip, includeDatabase: false)
        let logsOnly = try unpack(logsZip, in: folder.appendingPathComponent("only"))
        #expect(!FileManager.default.fileExists(atPath: logsOnly.appendingPathComponent("database-summary.json").path))
        let mode = try FileManager.default.attributesOfItem(atPath: logsZip.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func recordsMaintenanceFailureWithoutErrorDescriptionAndSerializesConcurrentWriters() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let log = DiagnosticLog(root: folder)
        let observer = log.maintenanceObserver(account: "test-account")
        #expect(throws: RepositoryError.self) {
            try DatabaseMaintenance.traced(.restore, observer: observer) {
                throw RepositoryError(message: "SECRET-ERROR-PATH")
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { log.record(.noteSaved, fields: ["count": "1"]) } }
        }
        let data = try Data(contentsOf: log.directory.appendingPathComponent("app.jsonl"))
        #expect(!String(decoding: data, as: UTF8.self).contains("SECRET"))
        let lines = data.split(separator: 0x0a)
        #expect(lines.count == 32)
        for line in lines { #expect(throws: Never.self) { _ = try JSONSerialization.jsonObject(with: Data(line)) } }
        #expect(String(decoding: data, as: UTF8.self).contains("failed"))
    }

    @Test func exportsAllConfiguredRotationsBeyondTheOriginalFourFileLimit() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "diagnostic-export-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = try LibraryStore(root: folder, profile: ConnectionProfile(), preferences: preferences)
        store.updateDiagnosticLogPolicy(DiagnosticLogPolicy(maximumFiles: 6, maximumTotalBytes: 16 * DiagnosticLogPolicy.mebibyte))
        let log = try #require(store.diagnosticLog)
        let original = try Data(contentsOf: log.directory.appendingPathComponent("app.jsonl"))
        for i in 1...5 { try original.write(to: log.directory.appendingPathComponent("app.\(i).jsonl")) }
        let zip = folder.appendingPathComponent("all-logs.zip")
        try await store.exportDiagnostics(to: zip, includeDatabase: false)
        let result = try unpack(zip, in: folder.appendingPathComponent("unpacked"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.appendingPathComponent("logs").path).count == 6)
        #expect(FileManager.default.fileExists(atPath: result.appendingPathComponent("logs/app.5.jsonl").path))
    }

    private func unpack(_ zip: URL, in folder: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return folder.appendingPathComponent("diagnostics")
    }
}
