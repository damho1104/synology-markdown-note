import Foundation
import Testing
@testable import SynologyNote

@Suite struct DiagnosticLogPolicyTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("log-policy-\(UUID().uuidString)") }

    private func files(_ log: DiagnosticLog) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: log.directory, includingPropertiesForKeys: nil)
            .filter { DiagnosticLog.rotationIndex(for: $0.lastPathComponent) != nil }
    }

    private func assertLimits(_ log: DiagnosticLog, _ policy: DiagnosticLogPolicy) throws {
        let urls = try files(log)
        #expect(urls.count <= policy.maximumFiles)
        var total = 0
        for url in urls {
            let data = try Data(contentsOf: url)
            total += data.count
            #expect(data.count <= policy.effectiveFileBytes)
            for line in data.split(separator: 0x0a) {
                #expect(throws: Never.self) { _ = try JSONSerialization.jsonObject(with: Data(line)) }
            }
        }
        #expect(total <= policy.maximumTotalBytes)
    }

    @Test func neverExceedsFileCountFileSizeOrTotalSizeAfterAnyWrite() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let policy = DiagnosticLogPolicy(maximumFileBytes: 650, maximumFiles: 4, maximumTotalBytes: 1000)
        let log = DiagnosticLog(root: folder, policy: policy)
        for i in 0..<40 {
            log.record(.noteSaved, fields: ["revision": String(i)])
            #expect(log.writeError == nil)
            try assertLimits(log, policy)
        }
        let all = try files(log).map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!all.contains("\"revision\":\"0\""))
        #expect(all.contains("\"revision\":\"39\""))
    }

    @Test func loweringPolicyAndRestartTrimExistingFilesWithoutTouchingUnrelatedFiles() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let log = DiagnosticLog(root: folder, policy: DiagnosticLogPolicy(maximumFileBytes: 1000, maximumFiles: 8, maximumTotalBytes: 8000))
        for i in 0..<30 { log.record(.noteSaved, fields: ["revision": String(i)]) }
        let unrelated = log.directory.appendingPathComponent("other.log")
        try Data("keep this file".utf8).write(to: unrelated)
        let policy = DiagnosticLogPolicy(maximumFileBytes: 500, maximumFiles: 2, maximumTotalBytes: 700)
        log.updatePolicy(policy)
        #expect(log.writeError == nil)
        try assertLimits(log, policy)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep this file")
        // Simulate an oversized file left by an older version while the app was closed.
        let valid = Data(("{\"event\":\"old\"}\n").utf8)
        try Data(repeating: 0x78, count: 2000).write(to: log.directory.appendingPathComponent("app.9.jsonl"))
        try (valid + valid + Data(repeating: 0x78, count: 1000) + Data([0x0a]) + valid)
            .write(to: log.directory.appendingPathComponent("app.jsonl"))
        let restarted = DiagnosticLog(root: folder, policy: policy)
        #expect(restarted.writeError == nil)
        try assertLimits(restarted, policy)
    }

    @Test func oneFileAndSmallTotalLimitStillRetainLatestCompleteEvent() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let policy = DiagnosticLogPolicy(maximumFileBytes: 2000, maximumFiles: 1, maximumTotalBytes: 600)
        let log = DiagnosticLog(root: folder, policy: policy)
        for i in 0..<10 { log.record(.noteSaved, fields: ["revision": String(i)]) }
        try assertLimits(log, policy)
        log.rotateNow()
        #expect(log.writeError == nil)
        try assertLimits(log, policy)
        log.record(.noteSaved, fields: ["revision": "999"])
        try assertLimits(log, policy)
        #expect(try String(contentsOf: log.directory.appendingPathComponent("app.jsonl"), encoding: .utf8).contains("999"))
        #expect(try files(log).count == 1)
    }

    @Test func oversizedSingleEventCannotBreakTheLimitAndLaterWritesRecover() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let log = DiagnosticLog(root: folder, policy: DiagnosticLogPolicy(maximumFileBytes: 1, maximumFiles: 2, maximumTotalBytes: 2))
        log.record(.noteSaved)
        #expect(log.writeError != nil)
        #expect(try files(log).isEmpty)
        log.updatePolicy(DiagnosticLogPolicy())
        log.record(.noteSaved)
        #expect(log.writeError == nil)
        #expect(try files(log).count == 1)
    }

    @Test func manualRotationCreatesNewCurrentAndHonorsCountWhenRepeated() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let policy = DiagnosticLogPolicy(maximumFileBytes: 1000, maximumFiles: 3, maximumTotalBytes: 2000)
        let log = DiagnosticLog(root: folder, policy: policy)
        for i in 0..<8 {
            log.record(.noteSaved, fields: ["revision": String(i)])
            log.rotateNow()
            #expect(log.writeError == nil)
            #expect(try Data(contentsOf: log.directory.appendingPathComponent("app.jsonl")).isEmpty)
            try assertLimits(log, policy)
        }
        #expect(try files(log).count == 3)
    }

    @Test func settingsRoundTripAndInvalidPreferencesAreBounded() {
        let name = "test-log-policy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(DiagnosticLogPolicy.load(from: defaults) == DiagnosticLogPolicy())
        let chosen = DiagnosticLogPolicy(maximumFileBytes: 5 * DiagnosticLogPolicy.mebibyte, maximumFiles: 9, maximumTotalBytes: 16 * DiagnosticLogPolicy.mebibyte)
        chosen.persist(to: defaults)
        #expect(DiagnosticLogPolicy.load(from: defaults) == chosen)
        let bounded = DiagnosticLogPolicy(maximumFileBytes: Int.max, maximumFiles: Int.max, maximumTotalBytes: Int.min)
        #expect(bounded.maximumFiles == 20)
        #expect(bounded.maximumFileBytes == 10 * DiagnosticLogPolicy.mebibyte)
        #expect(bounded.maximumTotalBytes == 1)
    }
}
