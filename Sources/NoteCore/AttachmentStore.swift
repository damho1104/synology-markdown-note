import Foundation
import CryptoKit
import UniformTypeIdentifiers

public enum AttachmentError: LocalizedError {
    case missing, corrupt, invalidPath
    public var errorDescription: String? {
        switch self {
        case .missing: return coreText("The attachment copy is missing. Add the original file again.")
        case .corrupt: return coreText("The attachment was modified or damaged. Add the original file again.")
        case .invalidPath: return coreText("The attachment path is unsafe.")
        }
    }
}

public actor AttachmentStore {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func importFile(_ source: URL) throws -> NoteAttachment {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        return try importData(Data(contentsOf: source), name: source.lastPathComponent)
    }
    public func importData(_ data: Data, name: String) throws -> NoteAttachment {
        let id = UUID()
        let fileExtension = (name as NSString).pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let filename = id.uuidString + (fileExtension.isEmpty ? "" : "." + String(fileExtension.prefix(12)))
        let target = directory.appendingPathComponent(filename)
        // Atomic rename finishes before a document can acquire a reference.
        try data.write(to: target, options: .atomic)
        let attachment = NoteAttachment(id: id, name: name, filename: filename, sha256: Self.hash(data), byteCount: data.count)
        _ = try verifiedData(for: attachment)
        return attachment
    }
    public func url(for attachment: NoteAttachment) -> URL { directory.appendingPathComponent(attachment.filename) }
    public func verifiedData(for attachment: NoteAttachment) throws -> Data {
        guard attachment.filename == (attachment.filename as NSString).lastPathComponent, !attachment.filename.contains("..") else { throw AttachmentError.invalidPath }
        guard let data = try? Data(contentsOf: url(for: attachment)) else { throw AttachmentError.missing }
        guard data.count == attachment.byteCount, Self.hash(data) == attachment.sha256 else { throw AttachmentError.corrupt }
        return data
    }
    public func removeUnreferencedCache(_ attachment: NoteAttachment) throws {
        guard attachment.filename == (attachment.filename as NSString).lastPathComponent, !attachment.filename.contains("..") else { throw AttachmentError.invalidPath }
        let file = url(for: attachment)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
