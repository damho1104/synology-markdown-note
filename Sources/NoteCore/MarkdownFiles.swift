import Foundation
import Markdown
import SwiftSoup

public enum MarkdownFileError: LocalizedError {
    case outsideDirectory, missingAsset(String), unsupportedEncoding
    public var errorDescription: String? {
        switch self {
        case .outsideDirectory: return coreText("Attachments outside the document’s folder are skipped. Copy the file into that folder and import again.")
        case .missingAsset(let name): return coreText("Attachment not found: %@", "\(name)")
        case .unsupportedEncoding: return coreText("Choose a UTF-8 Markdown file.")
        }
    }
}

public enum MarkdownFiles {
    /// Active attachment URLs only: code examples and front matter are literals.
    public static func attachmentReferences(in markdown: String, blocks: [PreservedBlock] = []) -> Set<String> {
        let syntax = MarkdownSyntax(markdown)
        var values = Set(syntax.destinationUses.filter { !syntax.isInFrontMatter($0.range) }.map(\.destination))
        let fragments = syntax.htmlRanges.filter { !syntax.isInFrontMatter($0) }.compactMap { syntax.byteRange($0).map(syntax.string) } + blocks.map(\.html)
        for fragment in fragments {
            guard let document = try? SwiftSoup.parseBodyFragment(fragment) else { continue }
            for element in (try? document.select("img[src],a[href]").array()) ?? [] {
                if let value = try? element.attr(element.tagNameNormal() == "img" ? "src" : "href") { values.insert(value) }
            }
        }
        return Set(values.filter { $0.lowercased().hasPrefix("attachment:") })
    }

    public static func importFile(_ source: URL, store: AttachmentStore) async throws -> NoteRecord {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let sourceData = try Data(contentsOf: source)
        guard let text = String(data: sourceData, encoding: .utf8) else { throw MarkdownFileError.unsupportedEncoding }

        let syntax = MarkdownSyntax(text)
        let parent = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var importedByPath: [String: NoteAttachment] = [:]
        var replacements: [ByteReplacement] = []
        var referenceReplacements: [String: String] = [:]

        for use in syntax.destinationUses {
            guard !syntax.isInFrontMatter(use.range) else { continue }
            guard let file = try localFile(for: use.destination, parent: parent) else { continue }
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw MarkdownFileError.missingAsset(use.destination.removingPercentEncoding ?? use.destination)
            }

            let key = file.path
            let attachment: NoteAttachment
            if let existing = importedByPath[key] {
                attachment = existing
            } else {
                attachment = try await store.importFile(file)
                importedByPath[key] = attachment
            }

            if let destinationRange = syntax.inlineDestinationRange(for: use.range) {
                replacements.append(ByteReplacement(range: destinationRange, text: attachment.reference))
            } else if let label = syntax.referenceLabel(for: use.range) {
                referenceReplacements[label] = attachment.reference
            }
        }

        replacements.append(contentsOf: syntax.referenceDefinitionReplacements(referenceReplacements))
        var note = NoteRecord(title: source.deletingPathExtension().lastPathComponent,
                              markdown: apply(replacements, to: text))
        note.attachments = importedByPath.values.sorted { $0.id.uuidString < $1.id.uuidString }
        return note
    }

    public static func export(_ note: NoteRecord, to destination: URL, store: AttachmentStore) async throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let assets = parent.appendingPathComponent("assets")
        var attachmentPaths: [UUID: String] = [:]

        let verified = try await note.attachments.asyncMap { attachment in
            (attachment, try await store.verifiedData(for: attachment))
        }
        for (attachment, data) in verified {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let output = try uniqueAssetURL(preferred: assets.appendingPathComponent(attachment.filename), data: data)
            try data.write(to: output, options: .atomic)
            attachmentPaths[attachment.id] = "assets/" + output.lastPathComponent
        }

        var destinationMap: [String: String] = [:]
        var htmlMarkers: [(String, String)] = []
        for attachment in note.attachments {
            guard let relative = attachmentPaths[attachment.id] else { continue }
            destinationMap[attachment.reference] = relative
            htmlMarkers.append((attachment.reference, relative))
            if let remoteID = attachment.remoteID, !remoteID.isEmpty {
                htmlMarkers.append((remoteID, relative))
            }
        }

        let text: String
        if note.mode == .original {
            text = rewriteHTML(note.originalHTML, markers: htmlMarkers)
        } else {
            let syntax = MarkdownSyntax(note.markdown)
            var replacements: [ByteReplacement] = []
            var referenceReplacements: [String: String] = [:]
            for use in syntax.destinationUses {
                guard !syntax.isInFrontMatter(use.range), let relative = destinationMap[use.destination] else { continue }
                if let range = syntax.inlineDestinationRange(for: use.range) {
                    replacements.append(ByteReplacement(range: range, text: relative))
                } else if let label = syntax.referenceLabel(for: use.range) {
                    referenceReplacements[label] = relative
                }
            }
            replacements.append(contentsOf: syntax.referenceDefinitionReplacements(referenceReplacements))

            for range in syntax.htmlRanges where !syntax.isInFrontMatter(range) {
                guard let byteRange = syntax.byteRange(range) else { continue }
                let fragment = syntax.string(in: byteRange)
                let rewritten = rewriteHTML(fragment, markers: htmlMarkers)
                if fragment != rewritten { replacements.append(ByteReplacement(range: byteRange, text: rewritten)) }
            }

            var markdown = apply(replacements, to: note.markdown)
            for block in note.activeBlocks {
                markdown = markdown.replacingOccurrences(of: MarkdownPipeline.token(for: block),
                                                          with: rewriteHTML(block.html, markers: htmlMarkers))
            }
            text = markdown
        }

        let activeBlocks = note.activeBlocks
        if !activeBlocks.isEmpty {
            let sidecar = availableSidecarURL(for: destination)
            try JSONEncoder().encode(activeBlocks).write(to: sidecar, options: .atomic)
        }
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }

    private static func localFile(for destination: String, parent: URL) throws -> URL? {
        guard !destination.isEmpty, !destination.hasPrefix("#") else { return nil }
        if destination.hasPrefix("//") { return nil }
        if destination.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil { return nil }
        let decoded = destination.removingPercentEncoding ?? destination
        guard !decoded.hasPrefix("/") else { throw MarkdownFileError.outsideDirectory }
        let file = parent.appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(parent.path + "/") else { throw MarkdownFileError.outsideDirectory }
        return file
    }

    private static func uniqueAssetURL(preferred: URL, data: Data) throws -> URL {
        guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }
        if try Data(contentsOf: preferred) == data { return preferred }
        let ext = preferred.pathExtension
        let stem = preferred.deletingPathExtension().lastPathComponent
        let parent = preferred.deletingLastPathComponent()
        for index in 1...9999 {
            let name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            if try Data(contentsOf: candidate) == data { return candidate }
        }
        throw RepositoryError(message: coreText("Could not generate a filename for the exported attachment."))
    }

    private static func availableSidecarURL(for destination: URL) -> URL {
        let parent = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent + ".preserved"
        let preferred = parent.appendingPathComponent(stem).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }
        var index = 1
        while true {
            let candidate = parent.appendingPathComponent("\(stem)-\(index)").appendingPathExtension("json")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private static func rewriteHTML(_ html: String, markers: [(String, String)]) -> String {
        var result = html
        for (marker, relative) in markers where !marker.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            let pattern = #"(?i)(\b(?:src|href)\s*=\s*)(["'])([^"']*"# + escaped + #"[^"']*)(["'])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let escapedReplacement = NSRegularExpression.escapedTemplate(for: relative)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1$2\(escapedReplacement)$4")
        }
        return result
    }

    private static func apply(_ replacements: [ByteReplacement], to text: String) -> String {
        guard !replacements.isEmpty else { return text }
        var data = Data(text.utf8)
        for replacement in replacements.sorted(by: { lhs, rhs in
            if lhs.range.lowerBound == rhs.range.lowerBound { return lhs.range.upperBound > rhs.range.upperBound }
            return lhs.range.lowerBound > rhs.range.lowerBound
        }) {
            guard replacement.range.lowerBound >= 0, replacement.range.upperBound <= data.count else { continue }
            data.replaceSubrange(replacement.range, with: Data(replacement.text.utf8))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct DestinationUse {
    var range: SourceRange
    var destination: String
}

private struct SyntaxCollector: MarkupWalker {
    var destinationUses: [DestinationUse] = []
    var htmlRanges: [SourceRange] = []

    mutating func visitImage(_ image: Image) {
        if let source = image.source, let range = image.range { destinationUses.append(DestinationUse(range: range, destination: source)) }
        descendInto(image)
    }
    mutating func visitLink(_ link: Link) {
        if let destination = link.destination, let range = link.range { destinationUses.append(DestinationUse(range: range, destination: destination)) }
        descendInto(link)
    }
    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        if let range = html.range { htmlRanges.append(range) }
    }
    mutating func visitInlineHTML(_ html: InlineHTML) {
        if let range = html.range { htmlRanges.append(range) }
    }
}

private struct ByteReplacement {
    var range: Range<Int>
    var text: String
}

private struct MarkdownSyntax {
    let text: String
    let data: Data
    let lineStarts: [Int]
    let frontMatterEndLine: Int?
    let destinationUses: [DestinationUse]
    let htmlRanges: [SourceRange]

    init(_ text: String) {
        self.text = text
        data = Data(text.utf8)
        var starts = [0]
        for (offset, byte) in data.enumerated() where byte == 0x0A { starts.append(offset + 1) }
        lineStarts = starts
        frontMatterEndLine = Self.detectFrontMatterEndLine(data: data, lineStarts: starts)
        var collector = SyntaxCollector()
        collector.visit(Document(parsing: text))
        destinationUses = collector.destinationUses
        htmlRanges = collector.htmlRanges
    }

    func isInFrontMatter(_ range: SourceRange) -> Bool {
        guard let end = frontMatterEndLine else { return false }
        return range.lowerBound.line <= end
    }

    func byteRange(_ sourceRange: SourceRange) -> Range<Int>? {
        guard sourceRange.lowerBound.line > 0, sourceRange.upperBound.line > 0,
              sourceRange.lowerBound.line <= lineStarts.count,
              sourceRange.upperBound.line <= lineStarts.count else { return nil }
        let lower = lineStarts[sourceRange.lowerBound.line - 1] + sourceRange.lowerBound.column - 1
        let upper = lineStarts[sourceRange.upperBound.line - 1] + sourceRange.upperBound.column - 1
        guard lower >= 0, upper >= lower, upper <= data.count else { return nil }
        return lower..<upper
    }

    func string(in range: Range<Int>) -> String {
        String(decoding: data[range], as: UTF8.self)
    }

    func inlineDestinationRange(for sourceRange: SourceRange) -> Range<Int>? {
        guard let whole = byteRange(sourceRange) else { return nil }
        let bytes = Array(data[whole])
        guard bytes.count >= 3 else { return nil }
        var delimiter: Int?
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 0x5D, bytes[index + 1] == 0x28 { delimiter = index }
            index += 1
        }
        guard let delimiter else { return nil }
        var cursor = delimiter + 2
        while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
        guard cursor < bytes.count else { return nil }

        if bytes[cursor] == 0x3C {
            let start = cursor + 1
            var end = start
            var escaped = false
            while end < bytes.count {
                let byte = bytes[end]
                if byte == 0x3E, !escaped { return (whole.lowerBound + start)..<(whole.lowerBound + end) }
                escaped = byte == 0x5C && !escaped
                if byte != 0x5C { escaped = false }
                end += 1
            }
            return nil
        }

        let start = cursor
        var depth = 0
        var escaped = false
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if escaped { escaped = false; cursor += 1; continue }
            if byte == 0x5C { escaped = true; cursor += 1; continue }
            if byte == 0x28 { depth += 1; cursor += 1; continue }
            if byte == 0x29 {
                if depth == 0 { break }
                depth -= 1; cursor += 1; continue
            }
            if depth == 0, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { break }
            cursor += 1
        }
        guard cursor > start else { return nil }
        return (whole.lowerBound + start)..<(whole.lowerBound + cursor)
    }

    func referenceLabel(for sourceRange: SourceRange) -> String? {
        guard let whole = byteRange(sourceRange) else { return nil }
        let raw = string(in: whole)
        guard let firstOpen = raw.firstIndex(of: "[") else { return nil }
        guard let firstClose = raw[firstOpen...].firstIndex(of: "]") else { return nil }
        let primary = String(raw[raw.index(after: firstOpen)..<firstClose])
        let after = raw.index(after: firstClose)
        if after < raw.endIndex, raw[after] == "[", let close = raw[raw.index(after: after)...].firstIndex(of: "]") {
            let explicit = String(raw[raw.index(after: after)..<close])
            return Self.normalizeLabel(explicit.isEmpty ? primary : explicit)
        }
        return Self.normalizeLabel(primary)
    }

    func referenceDefinitionReplacements(_ replacements: [String: String]) -> [ByteReplacement] {
        guard !replacements.isEmpty else { return [] }
        let pattern = #"^ {0,3}\[([^\]]+)\]:[ \t]*(<[^>]*>|[^ \t\r\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var results: [ByteReplacement] = []
        var usedLabels: Set<String> = []
        var fence: (byte: UInt8, count: Int)?

        for lineIndex in lineStarts.indices {
            let lineNumber = lineIndex + 1
            if let end = frontMatterEndLine, lineNumber <= end { continue }
            let start = lineStarts[lineIndex]
            var end = lineIndex + 1 < lineStarts.count ? lineStarts[lineIndex + 1] : data.count
            if end > start, data[end - 1] == 0x0A { end -= 1 }
            if end > start, data[end - 1] == 0x0D { end -= 1 }
            let lineData = data[start..<end]
            let bytes = Array(lineData)
            let indent = bytes.prefix(while: { $0 == 0x20 }).count
            if indent <= 3, indent < bytes.count, bytes[indent] == 0x60 || bytes[indent] == 0x7E {
                let marker = bytes[indent]
                let count = bytes[indent...].prefix(while: { $0 == marker }).count
                if count >= 3 {
                    if let active = fence {
                        if active.byte == marker, count >= active.count { fence = nil }
                    } else {
                        fence = (marker, count)
                    }
                    continue
                }
            }
            if fence != nil { continue }

            let line = String(decoding: lineData, as: UTF8.self)
            let full = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: full),
                  let labelRange = Range(match.range(at: 1), in: line),
                  let tokenRange = Range(match.range(at: 2), in: line) else { continue }
            let label = Self.normalizeLabel(String(line[labelRange]))
            guard !usedLabels.contains(label), let replacement = replacements[label] else { continue }
            usedLabels.insert(label)

            var inner = tokenRange
            if line[inner.lowerBound] == "<", line.index(before: inner.upperBound) > inner.lowerBound,
               line[line.index(before: inner.upperBound)] == ">" {
                inner = line.index(after: inner.lowerBound)..<line.index(before: inner.upperBound)
            }
            let lower = line[..<inner.lowerBound].utf8.count
            let upper = lower + line[inner].utf8.count
            results.append(ByteReplacement(range: (start + lower)..<(start + upper), text: replacement))
        }
        return results
    }

    private static func detectFrontMatterEndLine(data: Data, lineStarts: [Int]) -> Int? {
        guard !lineStarts.isEmpty else { return nil }
        func line(_ index: Int) -> String {
            let start = lineStarts[index]
            var end = index + 1 < lineStarts.count ? lineStarts[index + 1] : data.count
            if end > start, data[end - 1] == 0x0A { end -= 1 }
            if end > start, data[end - 1] == 0x0D { end -= 1 }
            return String(decoding: data[start..<end], as: UTF8.self)
        }
        guard line(0) == "---" else { return nil }
        guard lineStarts.count > 1 else { return nil }
        for index in 1..<lineStarts.count where line(index) == "---" { return index + 1 }
        return nil
    }

    private static func normalizeLabel(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}

