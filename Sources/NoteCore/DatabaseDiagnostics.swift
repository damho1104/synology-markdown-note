import Foundation
import CSQLite

/// Only aggregate values cross the diagnostics boundary; never SQL text or rows.
public struct DatabaseDiagnosticReport: Codable, Sendable {
    public let sqliteVersion: String
    public let schemaVersion: Int64
    public let integrityOK: Bool
    public let pageCount: Int64
    public let pageSize: Int64
    public let freePages: Int64
    public let tableCounts: [String: Int64]
    public let syncStateCounts: [String: Int64]
    public let orphanedSearchRows: Int64
    public let missingSearchRows: Int64
    public let mismatchedSearchRows: Int64
    public let backupCount: Int
    public let backupBytes: Int64
}

public struct DatabaseMaintenanceEvent: Sendable {
    public enum Operation: String, Sendable { case open, integrity, indexRepair, compaction, backup, restore, rollback }
    public enum Phase: String, Sendable { case started, completed, failed }
    public let operation: Operation
    public let phase: Phase
    public let metrics: [String: Int64]
}

extension DatabaseMaintenance {
    public typealias Observer = @Sendable (DatabaseMaintenanceEvent) -> Void

    /// Logging is optional and cannot change the outcome of maintenance.
    public static func traced<T>(_ operation: DatabaseMaintenanceEvent.Operation,
                                 observer: Observer, metrics: () -> [String: Int64] = { [:] },
                                 work: () throws -> T) rethrows -> T {
        let started = ProcessInfo.processInfo.systemUptime
        observer(.init(operation: operation, phase: .started, metrics: metrics()))
        do {
            let result = try work()
            var values = metrics()
            values["duration_ms"] = Int64((ProcessInfo.processInfo.systemUptime - started) * 1000)
            observer(.init(operation: operation, phase: .completed, metrics: values))
            return result
        } catch {
            // Error descriptions can contain user paths or data. Do not emit them.
            observer(.init(operation: operation, phase: .failed, metrics: [
                "duration_ms": Int64((ProcessInfo.processInfo.systemUptime - started) * 1000),
                "error_code": Int64((error as NSError).code)
            ]))
            throw error
        }
    }
}
