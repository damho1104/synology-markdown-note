import Foundation

public struct NoteAttachmentValidationReport: Codable, Sendable {
    public enum Stage: String, Codable, Sendable { case initialRead, imageUpload, imageRead, sourceUpload, finalRead, completed }
    public let receipt: WriteValidationReceipt
    public let checkedAt: Date
    public internal(set) var stage: Stage = .initialRead
    public internal(set) var imageBytesVerified = false
    public internal(set) var sourceBytesVerified = false
    public internal(set) var markdownRestored = false
    public internal(set) var finalVersion: String?
    public internal(set) var failure: String?
    public var passed: Bool { stage == .completed && imageBytesVerified && sourceBytesVerified && markdownRestored && failure == nil }
    init(receipt: WriteValidationReceipt) { self.receipt = receipt; checkedAt = Date() }
}
