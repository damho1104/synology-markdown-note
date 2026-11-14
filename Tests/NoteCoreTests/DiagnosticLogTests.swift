import Foundation
import Testing
import NoteCore
@testable import SynologyNote

@Suite @MainActor struct DiagnosticLogTests {
    @Test func recordsStructuredErrorCodesWithoutCredentialsBodiesOrErrorDescriptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(root: root)
        log.record(.connectionFailed, fields: ["password": "SECRET-PASSWORD", "otp": "SECRET-OTP", "body": "SECRET-BODY", "note_id": "note-123"], error: NoteStationError.invalidArgument("SECRET-TOKEN"))
        log.record(.uploadFailed, error: NoteStationError.api(code: 114))
        let text = try String(contentsOf: log.directory.appendingPathComponent("app.jsonl"), encoding: .utf8)
        #expect(!text.contains("SECRET"))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        let entry = try #require(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        let fields = try #require(entry["fields"] as? [String: String])
        #expect(entry["event"] as? String == "upload.failed")
        #expect(fields["error_kind"] == "api" && fields["error_code"] == "114")
        let permissions = try FileManager.default.attributesOfItem(atPath: log.directory.appendingPathComponent("app.jsonl").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func rotatesLogsAndRetainsOnlyConfiguredNumberOfBackups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(root: root, maximumBytes: 512, backups: 2)
        for _ in 0..<8 { log.record(.inspectorOpened) }
        let names = try FileManager.default.contentsOfDirectory(atPath: log.directory.path)
        #expect(Set(names) == ["app.jsonl", "app.1.jsonl", "app.2.jsonl"])
        for name in names {
            let bytes = try Data(contentsOf: log.directory.appendingPathComponent(name))
            #expect(bytes.count <= 512)
            for line in bytes.split(separator: 0x0a) {
                #expect(throws: Never.self) { _ = try JSONSerialization.jsonObject(with: Data(line)) }
            }
        }
    }

    @Test func stackFailuresRecordOnlyAllowlistedOperationAndErrorMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(root: root)
        log.record(.stackMutationStarted, fields: ["state": "create", "count": "3", "stack": "SECRET-STACK"])
        log.record(.stackMutationFailed, fields: ["state": "create.nas", "count": "3", "password": "SECRET-PASSWORD"], error: NoteStationError.api(code: 9999))
        let contents = try String(contentsOf: log.directory.appendingPathComponent("app.jsonl"), encoding: .utf8)
        #expect(!contents.contains("SECRET"))
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 2)
        let entry = try #require(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        let fields = try #require(entry["fields"] as? [String: String])
        #expect(entry["event"] as? String == "stack.mutation_failed")
        #expect(fields["state"] == "create.nas" && fields["count"] == "3")
        #expect(fields["error_kind"] == "api" && fields["error_code"] == "9999")
    }

    @Test func loggingFailureDoesNotThrowOrPreventApplicationWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: root.appendingPathComponent("logs"))
        let log = DiagnosticLog(root: root)
        log.record(.noteSaved)
        #expect(log.writeError != nil)
    }
}
