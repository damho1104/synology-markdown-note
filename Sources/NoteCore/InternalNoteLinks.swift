import Foundation
import Markdown
import SwiftSoup

/// Readable .md destinations are resolved locally; raw Markdown is kept intact for NAS sync.
public enum InternalNoteLinks {
    private static let documentPrefix = "synology-note://note/"
    private static let remotePrefix = "synology-note://remote/"
    public static let managedStart = "<!-- synology-note:related:start -->"
    public static let managedEnd = "<!-- synology-note:related:end -->"

    public static func documentID(for destination: String) -> UUID? {
        let value = destination.removingPercentEncoding ?? destination
        guard value.lowercased().hasPrefix(documentPrefix) else { return nil }
        let suffix = String(value.dropFirst(documentPrefix.count))
        guard suffix.count == 36 else { return nil }
        return UUID(uuidString: suffix)
    }

    public static func destination(for documentID: UUID) -> String {
        documentPrefix + documentID.uuidString.lowercased()
    }

    /// NAS object IDs are shared by clients even when a legacy note has no source envelope.
    public static func remoteID(for destination: String) -> String? {
        guard destination.lowercased().hasPrefix(remotePrefix) else { return nil }
        let suffix = String(destination.dropFirst(remotePrefix.count))
        guard !suffix.isEmpty, !suffix.contains("/"), !suffix.contains("?"), !suffix.contains("#"),
              let decoded = suffix.removingPercentEncoding, !decoded.isEmpty else { return nil }
        return decoded
    }

    public static func destination(for note: NoteSummary) -> String {
        if let id = note.sourceDocumentID { return destination(for: id) }
        if let remote = note.remoteID, !remote.isEmpty {
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
            return remotePrefix + (remote.addingPercentEncoding(withAllowedCharacters: allowed) ?? remote)
        }
        return destination(for: note.id)
    }

    /// All stable forms a note may have acquired before or after NAS import.
    /// Matching these is safe because they encode identities, never titles.
    public static func destinations(for note: NoteSummary) -> Set<String> {
        var result: Set<String> = [destination(for: note.id)]
        if let documentID = note.sourceDocumentID { result.insert(destination(for: documentID)) }
        if let remoteID = note.remoteID, !remoteID.isEmpty {
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
            result.insert(remotePrefix + (remoteID.addingPercentEncoding(withAllowedCharacters: allowed) ?? remoteID))
        }
        return result
    }

    public static func isInternal(_ destination: String) -> Bool {
        documentID(for: destination) != nil || remoteID(for: destination) != nil || title(for: destination) != nil
    }

    public static func link(_ label: String, documentID: UUID) -> String {
        link(label, destination: destination(for: documentID))
    }

    public static func link(_ label: String, target: NoteSummary) -> String {
        link(label, destination: destination(for: target))
    }

    private static func link(_ label: String, destination: String) -> String {
        let cleaned = label.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let escaped = cleaned.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](<\(destination)>)"
    }

    /// Only our delimited block is mutable; a user's similarly titled section is untouched.
    public static func managedRange(in markdown: String) -> Range<String.Index>? {
        guard let start = markdown.range(of: managedStart),
              let end = markdown.range(of: managedEnd, range: start.upperBound..<markdown.endIndex),
              markdown.range(of: managedStart, range: start.upperBound..<markdown.endIndex) == nil,
              markdown.range(of: managedEnd, range: end.upperBound..<markdown.endIndex) == nil,
              markdown.range(of: managedEnd, range: markdown.startIndex..<start.lowerBound) == nil else { return nil }
        return start.lowerBound..<end.upperBound
    }

    public static func managedDestinations(in markdown: String) -> Set<String> {
        guard let range = managedRange(in: markdown) else { return [] }
        return destinations(in: String(markdown[range]))
    }

    public static func hasManagedLink(_ markdown: String, to target: NoteSummary) -> Bool {
        !managedDestinations(in: markdown).isDisjoint(with: destinations(for: target))
    }

    public static func addManagedLink(_ markdown: String, label: String, documentID: UUID) -> String? {
        addManagedLink(markdown, label: label, destination: destination(for: documentID))
    }

    public static func addManagedLink(_ markdown: String, target: NoteSummary) -> String? {
        addManagedLink(markdown, label: target.title.isEmpty ? "제목 없음" : target.title,
                       destination: destination(for: target), aliases: destinations(for: target))
    }

    private static func addManagedLink(_ markdown: String, label: String, destination: String,
                                       aliases: Set<String>? = nil) -> String? {
        let item = "- " + link(label, destination: destination)
        if let range = managedRange(in: markdown) {
            guard managedDestinations(in: markdown).isDisjoint(with: aliases ?? [destination]) else { return markdown }
            let segment = String(markdown[range]); let cut = segment.range(of: managedEnd)!
            let updated = String(segment[..<cut.lowerBound]) + item + "\n" + String(segment[cut.lowerBound...])
            var result = markdown; result.replaceSubrange(range, with: updated); return result
        }
        // Fail closed for malformed/duplicated markers rather than rewriting user content.
        guard !markdown.contains(managedStart), !markdown.contains(managedEnd) else { return nil }
        let separator = markdown.isEmpty ? "" : (markdown.hasSuffix("\n") ? "\n" : "\n\n")
        return markdown + separator + managedStart + "\n## 관련 노트 (앱에서 관리)\n" + item + "\n" + managedEnd + "\n"
    }

    public static func removeManagedLink(_ markdown: String, documentID: UUID) -> String? {
        removeManagedLink(markdown, destination: destination(for: documentID))
    }

    public static func removeManagedLink(_ markdown: String, target: NoteSummary) -> String? {
        removeManagedLink(markdown, destinations: destinations(for: target))
    }

    private static func removeManagedLink(_ markdown: String, destination: String) -> String? {
        removeManagedLink(markdown, destinations: [destination])
    }

    private static func removeManagedLink(_ markdown: String, destinations identities: Set<String>) -> String? {
        guard let range = managedRange(in: markdown) else { return nil }
        let lines = String(markdown[range]).components(separatedBy: "\n")
        let filtered = lines.filter { line in
            guard line.hasPrefix("- ["), line.hasSuffix(">)"),
                  destinations(in: line).count == 1,
                  !destinations(in: line).isDisjoint(with: identities) else { return true }
            return false
        }
        guard filtered.count != lines.count else { return markdown }
        var result = markdown; result.replaceSubrange(range, with: filtered.joined(separator: "\n"))
        return result
    }

    public struct Completion: Equatable, Sendable {
        public let range: NSRange
        public let query: String
    }

    /// UTF-16 offsets match NSTextView. Ignore fenced/inline code and incomplete IME text.
    public static func completion(in text: String, caret: Int) -> Completion? {
        let ns = text as NSString
        guard caret >= 2, caret <= ns.length else { return nil }
        // Completing only the prefix at a moved caret would leave the trailing
        // search text behind ("[[alpha|bet" -> "[note](...)bet"). Close the
        // popup until the caret returns to the end of the typed query.
        if caret < ns.length, ns.character(at: caret) != 10 { return nil }
        let prior = ns.substring(to: caret)
        let lines = prior.components(separatedBy: "\n")
        var fence: (Character, Int)?
        for line in lines.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let character = trimmed.first
            guard character == "`" || character == "~" else { continue }
            let run = trimmed.prefix(while: { $0 == character }).count
            guard run >= 3 else { continue }
            if fence == nil { fence = (character!, run) }
            else if fence!.0 == character && run >= fence!.1 { fence = nil }
        }
        let line = lines.last ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let c = trimmed.first, (c == "`" || c == "~"), trimmed.prefix(while: { $0 == c }).count >= 3 { return nil }
        guard fence == nil, let open = line.range(of: "[[", options: .backwards) else { return nil }
        let query = String(line[open.upperBound...])
        guard !query.contains("]"), !query.contains("["), !query.contains("\r") else { return nil }
        // Markdown inline code opens with a backtick run and closes only with
        // a run of the same length. Counting individual ticks fails for ``code``.
        let prefix = line[..<open.lowerBound]
        var openRun: Int?
        var cursor = prefix.startIndex
        while cursor < prefix.endIndex {
            guard prefix[cursor] == "`" else { cursor = prefix.index(after: cursor); continue }
            var end = cursor
            while end < prefix.endIndex && prefix[end] == "`" { end = prefix.index(after: end) }
            let length = prefix.distance(from: cursor, to: end)
            if openRun == length { openRun = nil }
            else if openRun == nil { openRun = length }
            cursor = end
        }
        guard openRun == nil else { return nil }
        return Completion(range: NSRange(location: caret - ("[[" + query).utf16.count, length: ("[[" + query).utf16.count), query: query)
    }
    public static func title(for destination: String) -> String? {
        let decoded = destination.removingPercentEncoding ?? destination
        guard decoded.lowercased().hasSuffix(".md"), !decoded.contains("/"),
              !decoded.contains("\\"), !decoded.contains("?"), !decoded.contains("#"),
              !decoded.contains(":"), !decoded.contains("\n") else { return nil }
        let title = String(decoded.dropLast(3))
        return title.isEmpty ? nil : title
    }

    public static func destinations(in markdown: String) -> Set<String> {
        var collector = Collector()
        collector.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
        return collector.destinations
    }

    /// Rewrites preview links only; exported/source Markdown keeps its readable filename links.
    public static func previewHTML(_ html: String) -> String {
        guard (html.localizedCaseInsensitiveContains(".md") || html.contains(documentPrefix) || html.contains(remotePrefix)),
              let document = try? SwiftSoup.parseBodyFragment(html),
              let anchors = try? document.select("a[href]").array() else { return html }
        var changed = false
        for anchor in anchors {
            guard let destination = try? anchor.attr("href"), isInternal(destination) else { continue }
            var components = URLComponents()
            components.scheme = "synology-note"; components.host = "link"
            components.queryItems = [URLQueryItem(name: "destination", value: destination)]
            guard let url = components.url else { continue }
            try? anchor.attr("href", url.absoluteString)
            changed = true
        }
        return changed ? ((try? document.body()?.html()) ?? html) : html
    }

    private struct Collector: MarkupWalker {
        var destinations: Set<String> = []
        mutating func visitLink(_ link: Link) {
            if let destination = link.destination, InternalNoteLinks.isInternal(destination) {
                destinations.insert(destination)
            }
            descendInto(link)
        }
    }
}
