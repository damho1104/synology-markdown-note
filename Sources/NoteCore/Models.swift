import Foundation

public enum DocumentMode: String, Codable, Sendable { case markdown, original, locked }
public enum NoteSyncState: String, Codable, Sendable { case local, pending, synced, failed, conflict }
public enum OperationState: String, Codable, Sendable { case pending, failed, uncertain, conflict }

public struct NoteAttachment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var filename: String
    public var sha256: String
    public var byteCount: Int
    public var remoteID: String?
    public var remoteReference: String?
    public var generatedMath: MathAttachmentMetadata?
    public init(id: UUID = UUID(), name: String, filename: String, sha256: String, byteCount: Int, remoteID: String? = nil, remoteReference: String? = nil) {
        self.id = id; self.name = name; self.filename = filename; self.sha256 = sha256
        self.byteCount = byteCount; self.remoteID = remoteID
        self.remoteReference = remoteReference
    }
    public var reference: String { "attachment://\(id.uuidString)" }
}

public struct RemoteConflictSnapshot: Codable, Hashable, Sendable {
    public var html: String
    public var version: String?
    public var attachments: [NoteAttachment]
    public init(html: String, version: String?, attachments: [NoteAttachment]) {
        self.html = html
        self.version = version
        self.attachments = attachments
    }
}

public struct NoteRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var remoteID: String?
    public var title: String
    public var sourceDocumentID: UUID?
    public var notebookID: String
    public var markdown: String
    public var originalHTML: String
    public var blocks: [PreservedBlock]
    public var mode: DocumentMode
    public var tags: [String]
    public var attachments: [NoteAttachment]
    public var isFavorite: Bool
    public var isTrashed: Bool
    public var revision: Int
    public var serverVersion: String?
    public var listedVersion: String?
    public var hasRemoteContent: Bool
    public var baseHTML: String?
    public var conflictHTML: String?
    public var conflictVersion: String?
    public var conflictSnapshot: RemoteConflictSnapshot?
    /// Optional for notes saved before creation dates were persisted.
    public var createdAt: Date?
    public var modifiedAt: Date
    public var syncState: NoteSyncState
    public var lastError: String?

    public init(id: UUID = UUID(), title: String = "새 노트", notebookID: String = "local", markdown: String = "", mode: DocumentMode = .markdown) {
        self.id = id; self.title = title; self.notebookID = notebookID; self.markdown = markdown; self.mode = mode
        self.originalHTML = ""; self.blocks = []; self.tags = []; self.attachments = []
        self.isFavorite = false; self.isTrashed = false; self.revision = 0
        self.modifiedAt = Date(); self.createdAt = modifiedAt; self.syncState = .local
        self.hasRemoteContent = true
        self.conflictSnapshot = nil
    }

    public var summary: NoteSummary {
        NoteSummary(id: id, remoteID: remoteID, title: title, notebookID: notebookID,
                    excerpt: String(markdown.prefix(180)).replacingOccurrences(of: "\n", with: " "),
                    tags: tags, isFavorite: isFavorite, isTrashed: isTrashed, mode: mode,
                    createdAt: createdAt, modifiedAt: modifiedAt, syncState: syncState, lastError: lastError,
                    sourceDocumentID: sourceDocumentID)
    }
    /// Keep the registry for native undo; serialize only blocks still present in the document.
    public var activeBlocks: [PreservedBlock] { blocks.filter { markdown.contains(MarkdownPipeline.token(for: $0)) } }
}

public struct NoteSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var remoteID: String?
    public var title: String
    public var notebookID: String
    public var excerpt: String
    public var tags: [String]
    public var isFavorite: Bool
    public var isTrashed: Bool
    public var mode: DocumentMode
    public var createdAt: Date?
    public var modifiedAt: Date
    public var syncState: NoteSyncState
    public var lastError: String?
    /// Stable identity carried by the NAS Markdown source envelope. Nil for legacy imports.
    public var sourceDocumentID: UUID? = nil
    public var linkDocumentID: UUID { sourceDocumentID ?? id }
}

public struct Notebook: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var stack: String
    public init(id: String, name: String, stack: String = "") {
        self.id = id; self.name = name; self.stack = stack
    }

    private enum CodingKeys: String, CodingKey { case id, name, stack }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        stack = try values.decodeIfPresent(String.self, forKey: .stack) ?? ""
    }
}

/// A local, account-scoped query. Saved searches never create NAS notebooks.
public struct SavedSearch: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var query: String
    public var title: String
    public var tag: String
    public var notebookID: String?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?

    public init(id: UUID = UUID(), name: String, query: String = "", title: String = "", tag: String = "", notebookID: String? = nil, modifiedAfter: Date? = nil, modifiedBefore: Date? = nil) {
        self.id = id; self.name = name; self.query = query; self.title = title; self.tag = tag
        self.notebookID = notebookID; self.modifiedAfter = modifiedAfter; self.modifiedBefore = modifiedBefore
    }
}

public struct NoteRevision: Codable, Identifiable, Sendable {
    public var id: UUID
    public var noteID: UUID
    public var number: Int
    public var savedAt: Date
    public var note: NoteRecord
}

public struct PendingOperation: Codable, Identifiable, Sendable {
    public var id: UUID
    public var noteID: UUID
    public var revision: Int
    public var baseVersion: String?
    public var state: OperationState
    public var attempts: Int
    public var error: String?
    public var nextAttemptAt: Date
}
