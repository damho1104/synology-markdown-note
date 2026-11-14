import Foundation

/// Diagnostic receipt only; passing this probe does not enable production writes.
/// No credentials, request URLs, or user document bodies are retained.
public struct NoteEditingValidationReport: Codable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case initialRead, update, updateRead, staleWrite, conflictRead, completed
    }

    public let receipt: WriteValidationReceipt
    public let checkedAt: Date
    public internal(set) var stage: Stage = .initialRead
    public internal(set) var updatedVersion: String?
    public internal(set) var updateConfirmed = false
    public internal(set) var conflictRejected = false
    public internal(set) var latestContentPreserved = false
    public internal(set) var failure: String?

    public var passed: Bool {
        updateConfirmed && conflictRejected && latestContentPreserved && failure == nil && stage == .completed
    }

    init(receipt: WriteValidationReceipt) {
        self.receipt = receipt
        self.checkedAt = Date()
    }
}
