import Foundation
import CryptoKit

public enum SourceEnvelopeError: Error, Equatable, Sendable {
    case invalidEnvelope
    case unsupportedVersion
    case corruptSource
    case invalidBlocks
}

/// A standard Markdown attachment with one app-owned metadata comment followed
/// by the user's exact UTF-8 source (including front matter and line endings).
public struct SourceEnvelope: Hashable, Sendable {
    public let documentID: UUID
    public let markdown: String
    public let blocks: [PreservedBlock]
    public let bodyFingerprint: String
    public let operationID: UUID?
    public let isStaging: Bool
    public let attachmentBindings: [String: String]
    public let mathAttachments: [String: MathAttachmentMetadata]

    private static let prefix = "<!-- synology-note-source:v1 "
    private static let prefixV2 = "<!-- synology-note-source:v2 "
    private static let prefixV3 = "<!-- synology-note-source:v3 "
    private static let suffix = " -->"
    private static let fingerprintPrefix = "sha256-exact-v1:"

    private struct Metadata: Codable {
        var formatVersion: Int
        var fingerprintVersion: Int
        var documentID: UUID
        var bodyFingerprint: String
        var sourceFingerprint: String
        var blocksFingerprint: String
        var blocks: [PreservedBlock]
        var operationID: UUID?
        var isStaging: Bool?
        var attachmentBindings: [String: String]?
        var bindingsFingerprint: String?
        var mathAttachments: [String: MathAttachmentMetadata]?
        var mathFingerprint: String?
    }

    public init(documentID: UUID, markdown: String, blocks: [PreservedBlock], html: String,
                operationID: UUID? = nil, isStaging: Bool = false, attachmentBindings: [String: String] = [:],
                mathAttachments: [String: MathAttachmentMetadata] = [:]) {
        self.documentID = documentID
        self.markdown = markdown
        self.blocks = blocks
        self.bodyFingerprint = Self.fingerprint(html)
        self.operationID = operationID; self.isStaging = isStaging; self.attachmentBindings = attachmentBindings
        self.mathAttachments = mathAttachments
    }

    private init(metadata: Metadata, markdown: String) {
        self.documentID = metadata.documentID
        self.markdown = markdown
        self.blocks = metadata.blocks
        self.bodyFingerprint = metadata.bodyFingerprint
        self.operationID = metadata.operationID; self.isStaging = metadata.isStaging ?? false
        self.attachmentBindings = metadata.attachmentBindings ?? [:]
        self.mathAttachments = metadata.mathAttachments ?? [:]
    }

    public func encoded() -> Data {
        guard mathAttachments.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.isValid }) else { return Data() }
        let version = !mathAttachments.isEmpty ? 3 : operationID != nil || isStaging || !attachmentBindings.isEmpty ? 2 : 1
        let metadata = Metadata(formatVersion: version, fingerprintVersion: 1, documentID: documentID,
                                bodyFingerprint: bodyFingerprint, sourceFingerprint: Self.fingerprint(markdown),
                                blocksFingerprint: Self.blocksFingerprint(blocks), blocks: blocks,
                                operationID: operationID, isStaging: version >= 2 ? isStaging : nil,
                                attachmentBindings: version >= 2 ? attachmentBindings : nil,
                                bindingsFingerprint: version >= 2 ? Self.bindingsFingerprint(attachmentBindings) : nil,
                                mathAttachments: version == 3 ? mathAttachments : nil,
                                mathFingerprint: version == 3 ? Self.mathFingerprint(mathAttachments) : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // This closed metadata schema contains only finite, JSON-encodable values.
        // No caller-controlled Encodable implementations can throw here.
        let encodedMetadata = try! encoder.encode(metadata)
        let prefix = version == 3 ? Self.prefixV3 : version == 2 ? Self.prefixV2 : Self.prefix
        var data = Data((prefix + encodedMetadata.base64EncodedString() + Self.suffix + "\n").utf8)
        data.append(contentsOf: markdown.utf8)
        return data
    }

    public static func decode(_ data: Data) throws -> SourceEnvelope {
        guard let newline = data.firstIndex(of: 10),
              let header = String(data: data[..<newline], encoding: .utf8),
              (header.hasPrefix(prefix) || header.hasPrefix(prefixV2) || header.hasPrefix(prefixV3)), header.hasSuffix(suffix) else {
            throw SourceEnvelopeError.invalidEnvelope
        }
        let headerPrefix = header.hasPrefix(prefixV3) ? prefixV3 : header.hasPrefix(prefixV2) ? prefixV2 : prefix
        let base64 = String(header.dropFirst(headerPrefix.count).dropLast(suffix.count))
        guard let metadataData = Data(base64Encoded: base64) else { throw SourceEnvelopeError.invalidEnvelope }
        let metadata: Metadata
        do { metadata = try JSONDecoder().decode(Metadata.self, from: metadataData) }
        catch { throw SourceEnvelopeError.invalidEnvelope }
        guard [1, 2, 3].contains(metadata.formatVersion), metadata.fingerprintVersion == 1 else {
            throw SourceEnvelopeError.unsupportedVersion
        }
        if metadata.formatVersion >= 2 {
            guard let bindings = metadata.attachmentBindings,
                  bindings.keys.allSatisfy({ UUID(uuidString: $0) != nil }), bindings.values.allSatisfy({ !$0.isEmpty }),
                  Self.bindingsFingerprint(bindings) == metadata.bindingsFingerprint else { throw SourceEnvelopeError.corruptSource }
        }
        if metadata.formatVersion == 3 {
            guard let math = metadata.mathAttachments,
                  math.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.isValid }),
                  Self.mathFingerprint(math) == metadata.mathFingerprint else { throw SourceEnvelopeError.corruptSource }
        } else if metadata.mathAttachments != nil { throw SourceEnvelopeError.corruptSource }
        guard validFingerprint(metadata.bodyFingerprint), validFingerprint(metadata.sourceFingerprint),
              blocksFingerprint(metadata.blocks) == metadata.blocksFingerprint,
              let markdown = String(data: data[data.index(after: newline)...], encoding: .utf8),
              fingerprint(markdown) == metadata.sourceFingerprint else {
            throw SourceEnvelopeError.corruptSource
        }
        guard MarkdownPipeline.validateBlocks(markdown, blocks: metadata.blocks) else {
            throw SourceEnvelopeError.invalidBlocks
        }
        return SourceEnvelope(metadata: metadata, markdown: markdown)
    }

    public func matches(html: String) -> Bool {
        !isStaging && Self.validFingerprint(bodyFingerprint) && Self.fingerprint(html) == bodyFingerprint
    }

    /// New uploads use the original local UUID as the server attachment's ref.
    /// Rebind imported assets to that UUID, retaining exact source bytes on a
    /// different Mac. Unknown or ambiguous refs keep the document in HTML mode.
    public func restoredAttachments(from attachments: [NoteAttachment]) throws -> [NoteAttachment] {
        var restored = attachments
        let mathReferences = mathAttachments.keys.map { "attachment://" + $0 }
        for reference in MarkdownFiles.attachmentReferences(in: markdown, blocks: blocks) + mathReferences {
            guard let url = URL(string: reference), let id = UUID(uuidString: url.host ?? ""),
                  url.path.isEmpty, url.query == nil, url.fragment == nil else { throw SourceEnvelopeError.invalidEnvelope }
            let candidates = restored.indices.filter {
                if let remoteID = attachmentBindings.first(where: { UUID(uuidString: $0.key) == id })?.value {
                    return restored[$0].remoteID == remoteID
                }
                return restored[$0].id == id || restored[$0].remoteReference.flatMap(UUID.init(uuidString:)) == id
            }
            guard candidates.count == 1 else { throw SourceEnvelopeError.invalidEnvelope }
            restored[candidates[0]].id = id
            restored[candidates[0]].generatedMath = mathAttachments.first { UUID(uuidString: $0.key) == id }?.value
        }
        guard Set(restored.map(\.id)).count == restored.count else { throw SourceEnvelopeError.invalidEnvelope }
        return restored
    }

    /// v1 deliberately hashes exact UTF-8 bytes. NAS URL/token normalization has
    /// not been verified, so even cosmetic differences are treated as conflicts.
    public static func fingerprint(_ html: String) -> String {
        fingerprintPrefix + SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validFingerprint(_ value: String) -> Bool {
        guard value.hasPrefix(fingerprintPrefix) else { return false }
        let hash = value.dropFirst(fingerprintPrefix.count)
        return hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func blocksFingerprint(_ blocks: [PreservedBlock]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(blocks)
        return fingerprintPrefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func bindingsFingerprint(_ bindings: [String: String]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return fingerprint(String(decoding: try! encoder.encode(bindings), as: UTF8.self))
    }
    private static func mathFingerprint(_ values: [String: MathAttachmentMetadata]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return fingerprint(String(decoding: try! encoder.encode(values), as: UTF8.self))
    }
}
