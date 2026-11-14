import Foundation
import CSQLite

/// SQLite snapshots are account-local and are never copied from a live WAL file.
public enum DatabaseMaintenance {
    public struct Snapshot: Identifiable, Sendable {
        public let url: URL
        public let date: Date
        public let size: Int64
        public var id: URL { url }
    }

    private static let filename = "notes.sqlite3"
    private static let snapshotsFolder = "backups"
    private static let interval: TimeInterval = 12 * 60 * 60

    public static func snapshots(in directory: URL) -> [Snapshot] {
        let folder = directory.appendingPathComponent(snapshotsFolder, isDirectory: true)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return [] }
        return urls.compactMap { url -> Snapshot? in
            guard url.pathExtension == "sqlite3", url.lastPathComponent.hasPrefix("snapshot-"),
                  let attributes = try? url.resourceValues(forKeys: keys), attributes.isRegularFile == true else { return nil }
            return Snapshot(url: url, date: attributes.contentModificationDate ?? .distantPast,
                            size: Int64(attributes.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }

    /// Backs up a coherent snapshot, checks it, and publishes it only on success.
    @discardableResult
    public static func snapshot(from database: OpaquePointer, in directory: URL,
                                force: Bool = false, now: Date = Date(), observer: Observer = { _ in }) throws -> URL? {
        if !force, let latest = snapshots(in: directory).first, now.timeIntervalSince(latest.date) < interval { return nil }
        return try traced(.backup, observer: observer, metrics: {
            ["backup_count": Int64(snapshots(in: directory).count), "bytes": snapshots(in: directory).first?.size ?? 0]
        }) { try createSnapshot(from: database, in: directory, now: now) }
    }

    private static func createSnapshot(from database: OpaquePointer, in directory: URL, now: Date) throws -> URL {
        try checkIntegrity(database)
        let folder = directory.appendingPathComponent(snapshotsFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "snapshot-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString)"
        let pending = folder.appendingPathComponent(name + ".partial")
        let final = folder.appendingPathComponent(name + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: pending) }

        var target: OpaquePointer?
        guard sqlite3_open_v2(pending.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let target else {
            if let target { sqlite3_close(target) }
            throw RepositoryError(message: "백업 파일을 만들 수 없습니다.")
        }
        var result: Int32 = SQLITE_ERROR
        if let transfer = sqlite3_backup_init(target, "main", database, "main") {
            result = sqlite3_backup_step(transfer, -1)
            let finish = sqlite3_backup_finish(transfer)
            if result == SQLITE_DONE { result = finish }
        }
        let close = sqlite3_close(target)
        guard result == SQLITE_OK, close == SQLITE_OK else {
            throw RepositoryError(message: "SQLite 백업이 완료되지 않았습니다 (\(result)).")
        }
        try validateBackup(at: pending)
        try FileManager.default.moveItem(at: pending, to: final)
        pruneSnapshots(in: directory)
        return final
    }

    public static func checkIntegrity(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check(1)", -1, &statement, nil) == SQLITE_OK else {
            let path = sqlite3_db_filename(database, "main").map(String.init(cString:)) ?? "(unknown)"
            throw RepositoryError(message: "로컬 데이터베이스 무결성 검사를 시작할 수 없습니다 [\(path)]: \(String(cString: sqlite3_errmsg(database)))")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let message = sqlite3_column_text(statement, 0), String(cString: message) == "ok" else {
            throw RepositoryError(message: "로컬 데이터베이스 무결성 검사에 실패했습니다. 백업으로 복구할 수 있습니다.")
        }
    }

    public static func validateBackup(at url: URL) throws {
        var handle: OpaquePointer?
        // Online backups retain WAL journal mode in the database header. SQLite
        // may require -wal/-shm sidecars for an ordinary read-only open, even
        // though the backup itself is a complete, standalone database file.
        let immutableURL = url.absoluteString + "?immutable=1"
        guard sqlite3_open_v2(immutableURL, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw RepositoryError(message: "백업을 열 수 없습니다.")
        }
        defer { sqlite3_close(handle) }
        try checkIntegrity(handle)
        var statement: OpaquePointer?
        let required = ["notes", "revisions", "operations", "sync_attempts", "search_documents"]
        guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('notes','revisions','operations','sync_attempts','search_documents')", -1, &statement, nil) == SQLITE_OK else {
            throw RepositoryError(message: "백업의 데이터 구조를 검사할 수 없습니다.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == Int32(required.count) else {
            throw RepositoryError(message: "필수 데이터 구조가 누락된 백업입니다.")
        }
    }

    /// Use only with no open repository connection. Keep the old DB and its WAL for investigation.
    @discardableResult
    public static func restore(_ selected: URL, in directory: URL, observer: Observer = { _ in }) throws -> URL {
        try traced(.restore, observer: observer) { try restoreFiles(selected, in: directory) }
    }

    private static func restoreFiles(_ selected: URL, in directory: URL) throws -> URL {
        let available = snapshots(in: directory)
        guard available.contains(where: { $0.url.standardizedFileURL == selected.standardizedFileURL }) else {
            throw RepositoryError(message: "해당 계정의 백업 목록에 없는 파일입니다.")
        }
        try validateBackup(at: selected)
        let fm = FileManager.default
        let staging = directory.appendingPathComponent("restore-\(UUID().uuidString).pending")
        try fm.copyItem(at: selected, to: staging)
        defer { try? fm.removeItem(at: staging) }
        try validateBackup(at: staging)

        let quarantine = directory.appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent("before-restore-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let files = [filename, filename + "-wal", filename + "-shm"]
        var moved: [String] = []
        do {
            for file in files {
                let source = directory.appendingPathComponent(file)
                if fm.fileExists(atPath: source.path) {
                    try fm.moveItem(at: source, to: quarantine.appendingPathComponent(file))
                    moved.append(file)
                }
            }
            try fm.moveItem(at: staging, to: directory.appendingPathComponent(filename))
            // A successful restore is still retained in quarantine for manual inspection.
            return quarantine
        } catch {
            var rollbackFailures: [String] = []
            for file in moved.reversed() {
                let saved = quarantine.appendingPathComponent(file)
                let destination = directory.appendingPathComponent(file)
                if !fm.fileExists(atPath: destination.path) {
                    do { try fm.moveItem(at: saved, to: destination) }
                    catch { rollbackFailures.append("\(file): \(error.localizedDescription)") }
                } else {
                    rollbackFailures.append("\(file): 원래 위치에 다른 파일이 있습니다")
                }
            }
            if !rollbackFailures.isEmpty {
                throw RepositoryError(message: "복구 도중 오류가 발생했고 원본 파일 일부를 되돌리지 못했습니다. \(quarantine.path) 폴더를 보존하세요: \(rollbackFailures.joined(separator: "; "))")
            }
            throw error
        }
    }

    /// Undo a restore if the application cannot open the restored DB. Both the
    /// original DB/WAL and the failed restored files remain available to inspect.
    public static func rollbackRestore(in directory: URL, from quarantine: URL, observer: Observer = { _ in }) throws {
        try traced(.rollback, observer: observer) { try rollbackFiles(in: directory, from: quarantine) }
    }

    private static func rollbackFiles(in directory: URL, from quarantine: URL) throws {
        let recovery = directory.appendingPathComponent("recovery", isDirectory: true).standardizedFileURL
        guard quarantine.deletingLastPathComponent().standardizedFileURL == recovery else {
            throw RepositoryError(message: "복구 원본의 위치가 올바르지 않습니다.")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: quarantine.appendingPathComponent(filename).path) else {
            throw RepositoryError(message: "되돌릴 원본 DB가 격리 폴더에 없습니다. 현재 DB를 유지하고 \(quarantine.path) 폴더를 확인하세요.")
        }
        let failed = recovery.appendingPathComponent("failed-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: failed, withIntermediateDirectories: true)
        let names = [filename, filename + "-wal", filename + "-shm"]
        var movedFailed: [String] = [], restoredOriginal: [String] = []
        do {
            for name in names {
                let live = directory.appendingPathComponent(name)
                if fm.fileExists(atPath: live.path) {
                    try fm.moveItem(at: live, to: failed.appendingPathComponent(name))
                    movedFailed.append(name)
                }
            }
            for name in names {
                let saved = quarantine.appendingPathComponent(name)
                if fm.fileExists(atPath: saved.path) {
                    try fm.moveItem(at: saved, to: directory.appendingPathComponent(name))
                    restoredOriginal.append(name)
                }
            }
        } catch {
            let originalError = error
            var rollbackFailures: [String] = []
            for name in restoredOriginal.reversed() {
                do { try fm.moveItem(at: directory.appendingPathComponent(name), to: quarantine.appendingPathComponent(name)) }
                catch { rollbackFailures.append("격리 파일 \(name): \(error.localizedDescription)") }
            }
            for name in movedFailed.reversed() {
                do { try fm.moveItem(at: failed.appendingPathComponent(name), to: directory.appendingPathComponent(name)) }
                catch { rollbackFailures.append("복구 파일 \(name): \(error.localizedDescription)") }
            }
            if !rollbackFailures.isEmpty {
                throw RepositoryError(message: "DB 복구 되돌리기에 실패했습니다. 원본은 \(quarantine.path), 복구본은 \(failed.path)에서 보존하세요: \(rollbackFailures.joined(separator: "; "))")
            }
            throw originalError
        }
    }

    private static func pruneSnapshots(in directory: URL) {
        let entries = snapshots(in: directory)
        guard entries.count > 1 else { return }
        let calendar = Calendar(identifier: .gregorian)
        var days: Set<Date> = [], weeks: Set<Date> = []
        var retained: Set<URL> = []
        for item in entries {
            let day = calendar.startOfDay(for: item.date)
            if days.count < 7, !days.contains(day) {
                days.insert(day)
                retained.insert(item.url)
            }
        }
        for item in entries where !retained.contains(item.url) {
            let day = calendar.startOfDay(for: item.date)
            let week = calendar.dateInterval(of: .weekOfYear, for: item.date)?.start ?? day
            if weeks.count < 4, !weeks.contains(week) {
                weeks.insert(week)
                retained.insert(item.url)
            }
        }
        for item in entries where !retained.contains(item.url) { try? FileManager.default.removeItem(at: item.url) }
    }
}
