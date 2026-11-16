import Foundation
import CryptoKit
import Markdown
import SwiftSoup

/// Original server HTML. Preview sanitization must never modify this payload.
public struct PreservedBlock: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var html: String
    public var label: String

    public init(id: String = UUID().uuidString, html: String, label: String) {
        self.id = id
        self.html = html
        self.label = label
    }
}

public struct ImportedDocument: Sendable {
    public var markdown: String
    public var blocks: [PreservedBlock]
    public var safeToEdit: Bool

    public init(markdown: String, blocks: [PreservedBlock], safeToEdit: Bool) {
        self.markdown = markdown
        self.blocks = blocks
        self.safeToEdit = safeToEdit
    }
}

public enum MarkdownPipeline {
    /// Preview-only rendering. Server HTML continues to use `render`.
    public static func renderForPreview(_ markdown: String, blocks: [PreservedBlock] = [], sourceLines: Bool = false) -> String {
        guard validateBlocks(markdown, blocks: blocks) else { return "" }
        let frontMatter = MarkdownFrontMatter.extract(from: markdown)
        let body = frontMatter?.body ?? markdown
        let source = MathPreviewSource(body)
        let rendered = source.restoringFormulas(in: render(source.markdown, blocks: blocks, sourceLines: sourceLines, sourceLineOffset: markdown.components(separatedBy: "\n").count - body.components(separatedBy: "\n").count))
        guard let frontMatter else { return rendered }
        return """
        <details class="note-frontmatter"><summary>문서 정보</summary><pre><code>\(htmlEscape(frontMatter.metadata))</code></pre></details>
        \(rendered)
        """
    }

    public static func token(for block: PreservedBlock) -> String {
        ":::synology-block \(block.id) :::"
    }

    /// Server HTML, including untouched opaque payloads. Use `previewPage` for display.
    /// Invalid block references produce no HTML; callers must validate before saving.
    public static func render(_ markdown: String, blocks: [PreservedBlock] = [], sourceLines: Bool = false, sourceLineOffset: Int = 0) -> String {
        let math = MathPreviewSource(markdown)
        let source = MarkdownSource(math.markdown)
        let document = Markdown.Document(parsing: math.markdown, options: [.disableSmartOpts])
        guard source.validate(document, blocks: blocks) else { return "" }
        var renderer = ServerHTMLRenderer(source: source, blocks: Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.html) }), sourceLines: sourceLines, sourceLineOffset: sourceLineOffset)
        return math.restoringSource(in: renderer.visit(document))
    }

    public static func importHTML(_ html: String) -> ImportedDocument {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            document.outputSettings().prettyPrint(pretty: false)
            let nodes = document.body()?.getChildNodes() ?? []
            // SwiftSoup 2.13.6 retains source slices when pretty printing is disabled.
            // Never serialize a repaired DOM and mistake it for the original payload.
            let slices = try nodes.map { try $0.outerHtml() }
            guard Data(slices.joined().utf8) == Data(html.utf8) else {
                return preservedDocument(html, safeToEdit: false)
            }
            var blocks: [PreservedBlock] = []
            var parts: [String] = []
            var occurrences: [String: Int] = [:]
            for (node, raw) in zip(nodes, slices) {
                if let converted = try HTMLImporter.convert(node) {
                    let text = converted.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { parts.append(text) }
                } else {
                    let occurrence = occurrences[raw, default: 0]
                    occurrences[raw] = occurrence + 1
                    let block = makeBlock(raw, occurrence: occurrence, label: HTMLImporter.label(node))
                    blocks.append(block)
                    parts.append(token(for: block))
                }
            }
            return ImportedDocument(markdown: parts.joined(separator: "\n\n"), blocks: blocks, safeToEdit: true)
        } catch {
            return preservedDocument(html, safeToEdit: false)
        }
    }

    /// An allowlist DOM serializer: original payloads are never modified in place.
    public static func sanitize(_ html: String) -> String {
        guard let document = try? SwiftSoup.parseBodyFragment(html) else { return "" }
        return (document.body()?.getChildNodes() ?? []).map { PreviewSanitizer.serialize($0) }.joined()
    }

    public static func previewPage(_ html: String) -> String {
        // CSP blocks automatic requests. The WKWebView host disables JavaScript
        // and routes activated safe links through its navigation delegate.
        let body = sanitize(html)
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src data: attachment:; style-src 'unsafe-inline'; font-src data:; media-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html{overflow-y:scroll;scrollbar-gutter:stable;overflow-anchor:none}:root{color-scheme:light dark}body{font:15px -apple-system,sans-serif;line-height:1.7;overflow-wrap:anywhere;margin:24px}pre,code{font-family:ui-monospace,monospace}pre{white-space:pre-wrap;padding:14px;background:light-dark(#f4f5f7,#27292e);border-radius:6px}table{border-collapse:collapse}th,td{border:1px solid gray;padding:6px 10px}img{max-width:100%;height:auto}blockquote{border-left:3px solid gray;margin-left:0;padding-left:16px}li>p{display:inline;margin:0}li{margin:5px 0}li:has(>.task-toggle){list-style:none}.task-toggle{text-decoration:none;font-size:18px;margin-right:7px;color:light-dark(#3375c9,#8bb6ff)}h1{font-size:1.8em}h2{font-size:1.35em;margin-top:1.7em}a{color:light-dark(#246cc4,#8bb6ff)}.note-frontmatter{border:1px solid light-dark(#ddd,#505050);border-radius:8px;padding:8px 12px;background:light-dark(#fafafa,#252525)}.note-frontmatter summary{cursor:pointer;font-weight:600}.note-frontmatter pre{white-space:pre-wrap;overflow-wrap:anywhere;max-height:340px;overflow:auto;margin-bottom:2px}</style>
        </head><body>\(body)</body></html>
        """
    }

    /// All payloads must be referenced exactly once. Deliberate deletion requires
    /// removing both the token and its payload in the same document edit.
    public static func validateBlocks(_ markdown: String, blocks: [PreservedBlock] = []) -> Bool {
        MarkdownSource(markdown).validate(Markdown.Document(parsing: markdown, options: [.disableSmartOpts]), blocks: blocks)
    }

    private static func makeBlock(_ html: String, occurrence: Int, label: String) -> PreservedBlock {
        let hash = SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
        return PreservedBlock(id: "block-\(hash)-\(occurrence)", html: html, label: label)
    }

    private static func preservedDocument(_ html: String, safeToEdit: Bool) -> ImportedDocument {
        let block = makeBlock(html, occurrence: 0, label: "원본 HTML")
        return ImportedDocument(markdown: token(for: block), blocks: [block], safeToEdit: safeToEdit)
    }
}

/// Extract only a complete document-leading YAML block for preview display.
/// Do not parse or normalize the YAML: flow mappings, comments, and unknown keys
/// must remain readable and the original Markdown must stay byte-for-byte intact.
private enum MarkdownFrontMatter {
    static func extract(from markdown: String) -> (metadata: String, body: String)? {
        let bytes = Array(markdown.utf8)
        let start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0

        func line(at offset: Int) -> (content: ArraySlice<UInt8>, next: Int)? {
            guard offset < bytes.count else { return nil }
            var end = offset
            while end < bytes.count, bytes[end] != 0x0A, bytes[end] != 0x0D { end += 1 }
            let next: Int
            if end < bytes.count, bytes[end] == 0x0D, end + 1 < bytes.count, bytes[end + 1] == 0x0A {
                next = end + 2
            } else {
                next = min(end + 1, bytes.count)
            }
            return (bytes[offset..<end], next)
        }

        guard let opening = line(at: start), opening.content.elementsEqual([45, 45, 45]),
              opening.next < bytes.count else { return nil }
        let metadataStart = opening.next
        var offset = metadataStart
        while let current = line(at: offset) {
            if current.content.elementsEqual([45, 45, 45]) || current.content.elementsEqual([46, 46, 46]) {
                let metadata = String(decoding: bytes[metadataStart..<offset], as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                return (metadata, String(decoding: bytes[current.next...], as: UTF8.self))
            }
            guard current.next > offset else { break }
            offset = current.next
        }
        return nil
    }
}

private func htmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private struct MarkdownSource {
    let bytes: [UInt8]
    let lineStarts: [Int]

    init(_ text: String) {
        bytes = Array(text.utf8)
        var starts = [0]
        for i in bytes.indices {
            if bytes[i] == 10 || (bytes[i] == 13 && (i + 1 == bytes.count || bytes[i + 1] != 10)) {
                starts.append(i + 1)
            }
        }
        lineStarts = starts
    }

    func raw(_ markup: Markup) -> String {
        guard let range = markup.range,
              range.lowerBound.line > 0, range.upperBound.line > 0,
              range.lowerBound.line <= lineStarts.count, range.upperBound.line <= lineStarts.count else { return "" }
        let start = lineStarts[range.lowerBound.line - 1] + range.lowerBound.column - 1
        let end = lineStarts[range.upperBound.line - 1] + range.upperBound.column - 1
        guard start >= 0, end >= start, end <= bytes.count else { return "" }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    func tokenID(_ paragraph: Paragraph) -> String? {
        let text = raw(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = ":::synology-block "
        guard text.hasPrefix(prefix), text.hasSuffix(" :::") else { return nil }
        let id = String(text.dropFirst(prefix.count).dropLast(4))
        return validID(id) ? id : nil
    }

    func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    func validate(_ document: Markdown.Document, blocks: [PreservedBlock]) -> Bool {
        let ids = blocks.map(\.id)
        guard ids.allSatisfy(validID), Set(ids).count == ids.count else { return false }
        var referenced: [String] = []
        var valid = true
        func walk(_ node: Markup) {
            if let paragraph = node as? Paragraph {
                if let id = tokenID(paragraph) {
                    referenced.append(id)
                } else if raw(paragraph).split(whereSeparator: { $0.isNewline }).contains(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix(":::synology-block")
                }) {
                    valid = false
                }
            }
            for child in node.children { walk(child) }
        }
        walk(document)
        return valid && Set(referenced).count == referenced.count && Set(referenced) == Set(ids)
    }
}

/// Uses swift-markdown's CommonMark/GFM AST; source strings are never regex-rendered.
private struct ServerHTMLRenderer: MarkupVisitor {
    typealias Result = String
    let source: MarkdownSource
    let blocks: [String: String]
    var sourceLines = false
    var sourceLineOffset = 0

    mutating func defaultVisit(_ markup: Markup) -> String {
        var result = ""
        for child in markup.children {
            let rendered = visit(child)
            if sourceLines, markup is Markdown.Document, let line = child.range?.lowerBound.line {
                result += "<div data-source-line=\"\(line + sourceLineOffset)\">\(rendered)</div>"
            } else { result += rendered }
        }
        return result
    }

    mutating func wrapped(_ tag: String, _ node: Markup) -> String {
        "<\(tag)>\(defaultVisit(node))</\(tag)>"
    }

    mutating func visitText(_ text: Markdown.Text) -> String { htmlEscape(text.string) }
    mutating func visitStrong(_ strong: Strong) -> String { wrapped("strong", strong) }
    mutating func visitEmphasis(_ emphasis: Emphasis) -> String { wrapped("em", emphasis) }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String { wrapped("del", strikethrough) }
    mutating func visitHeading(_ heading: Heading) -> String { wrapped("h\(heading.level)", heading) + "\n" }
    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String { wrapped("blockquote", blockQuote) + "\n" }
    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        if let id = source.tokenID(paragraph), let html = blocks[id] { return html + "\n" }
        return wrapped("p", paragraph) + "\n"
    }
    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String { "<hr>\n" }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { "\n" }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "<br>\n" }
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String { html.rawHTML }
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String { inlineHTML.rawHTML }
    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String { "<code>\(htmlEscape(inlineCode.code))</code>" }
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let language = codeBlock.language?.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        let attribute = language.map { " class=\"language-\(htmlEscape($0))\"" } ?? ""
        return "<pre><code\(attribute)>\(htmlEscape(codeBlock.code))</code></pre>\n"
    }
    mutating func visitLink(_ link: Markdown.Link) -> String {
        let href = link.destination.map { " href=\"\(htmlEscape($0))\"" } ?? ""
        let title = link.title.map { " title=\"\(htmlEscape($0))\"" } ?? ""
        return "<a\(href)\(title)>\(defaultVisit(link))</a>"
    }
    mutating func visitImage(_ image: Markdown.Image) -> String {
        let src = image.source.map { " src=\"\(htmlEscape($0))\"" } ?? ""
        let title = image.title.map { " title=\"\(htmlEscape($0))\"" } ?? ""
        return "<img\(src) alt=\"\(htmlEscape(image.plainText))\"\(title)>"
    }
    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String { wrapped("ul", unorderedList) + "\n" }
    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        let start = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        return "<ol\(start)>\(defaultVisit(orderedList))</ol>\n"
    }
    mutating func visitListItem(_ listItem: ListItem) -> String {
        let task = listItem.range.map { " data-md-task=\"\($0.lowerBound.line)\"" } ?? ""
        let checkbox = listItem.checkbox.map { "<input type=\"checkbox\"\(task) disabled\($0 == .checked ? " checked" : "")> " } ?? ""
        return "<li>\(checkbox)\(defaultVisit(listItem))</li>\n"
    }
    mutating func visitTable(_ table: Markdown.Table) -> String {
        func alignment(_ column: Int) -> String {
            guard column < table.columnAlignments.count, let value = table.columnAlignments[column] else { return "" }
            return " align=\"\(value)\""
        }
        var result = "<table><thead><tr>"
        for (index, cell) in table.head.children.enumerated() {
            result += "<th\(alignment(index))>\(defaultVisit(cell))</th>"
        }
        result += "</tr></thead><tbody>"
        for row in table.body.children {
            result += "<tr>"
            for (index, cell) in row.children.enumerated() {
                result += "<td\(alignment(index))>\(defaultVisit(cell))</td>"
            }
            result += "</tr>"
        }
        return result + "</tbody></table>\n"
    }
}

/// Converts only understood DOM structures. Any unsupported descendant makes
/// its containing top-level block opaque, retaining attributes and boundaries.
private enum HTMLImporter {
    static func label(_ node: Node) -> String {
        guard let element = node as? Element else { return "원본 HTML" }
        if element.tagNameNormal() == "table" { return "원본 표" }
        if (try? element.select("audio").isEmpty()) == false { return "음성 첨부" }
        return "원본 서식"
    }

    static func attributesAllowed(_ element: Element, _ allowed: Set<String> = []) -> Bool {
        (element.getAttributes()?.asList() ?? []).allSatisfy { allowed.contains($0.getKey().lowercased()) }
    }

    static func escape(_ text: String) -> String {
        let math = MathPreviewSource(text)
        let special = Set("\\`*_{}[]()#+-.!>|~:<&")
        // Backslash-escaped literal brackets would themselves look like TeX
        // delimiters to the next render. Entities stay ordinary text in the AST.
        let brackets: [Character: String] = ["[": "&#91;", "]": "&#93;", "(": "&#40;", ")": "&#41;"]
        let escaped = math.markdown.map { brackets[$0] ?? (special.contains($0) ? "\\\($0)" : String($0)) }.joined()
        return math.restoringMarkdown(in: escaped)
    }

    static func children(_ node: Node, skipping: Node? = nil) throws -> String? {
        var result = ""
        for child in node.getChildNodes() {
            if child === skipping { continue }
            guard let converted = try convert(child, skipping: skipping) else { return nil }
            result += converted
        }
        return result
    }

    static func textContent(_ node: Node) -> String {
        if let text = node as? TextNode { return text.getWholeText() }
        return node.getChildNodes().map(textContent).joined()
    }

    static func code(_ text: String, block: Bool, language: String = "") -> String {
        let runs = text.split(whereSeparator: { $0 != "`" }).map(\.count)
        let fence = String(repeating: "`", count: max(block ? 3 : 1, (runs.max() ?? 0) + 1))
        if block { return "\n\n\(fence)\(language)\n\(text)\(text.hasSuffix("\n") ? "" : "\n")\(fence)\n\n" }
        let padding = text.hasPrefix("`") || text.hasSuffix("`") || (text.hasPrefix(" ") && text.hasSuffix(" ")) ? " " : ""
        return "\(fence)\(padding)\(text)\(padding)\(fence)"
    }

    static func link(_ element: Element, content: String, image: Bool) throws -> String? {
        let destination = try element.attr(image ? "src" : "href")
        let title = try element.attr("title")
        guard !content.contains("\n"), !destination.contains(where: { $0.isNewline || $0 == "<" || $0 == ">" }),
              !title.contains(where: { $0.isNewline }) else { return nil }
        let escapedDestination: String
        if destination.isEmpty || destination.contains(where: { $0.isWhitespace }) {
            escapedDestination = "<" + destination.replacingOccurrences(of: "\\", with: "\\\\") + ">"
        } else {
            escapedDestination = destination.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
        }
        let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let titlePart = element.hasAttr("title") ? " \"\(escapedTitle)\"" : ""
        return "\(image ? "!" : "")[\(content)](\(escapedDestination)\(titlePart))"
    }

    static func convert(_ node: Node, skipping: Node? = nil) throws -> String? {
        if let text = node as? TextNode {
            let math = MathPreviewSource(text.getWholeText())
            let normalized = math.markdown.replacingOccurrences(of: "[\\t\\n\\r ]+", with: " ", options: .regularExpression)
            return math.restoringMarkdown(in: escape(normalized))
        }
        guard let element = node as? Element else { return nil }
        let tag = element.tagNameNormal()
        switch tag {
        case "a":
            guard attributesAllowed(element, ["href", "title"]), element.hasAttr("href"), let content = try children(element) else { return nil }
            return try link(element, content: content, image: false)
        case "img":
            guard attributesAllowed(element, ["src", "alt", "title"]), element.hasAttr("src") else { return nil }
            return try link(element, content: escape(element.attr("alt")), image: true)
        case "pre":
            guard attributesAllowed(element) else { return nil }
            let children = element.children().array()
            guard children.count <= 1 else { return nil }
            var language = ""
            if let child = children.first {
                guard child.tagNameNormal() == "code", attributesAllowed(child, ["class"]) else { return nil }
                let classes = try child.attr("class")
                if !classes.isEmpty {
                    guard classes.hasPrefix("language-"), !classes.contains(where: { $0.isWhitespace }) else { return nil }
                    language = String(classes.dropFirst(9))
                    guard language.allSatisfy({ $0.isLetter || $0.isNumber || "_+-".contains($0) }) else { return nil }
                }
            }
            return code(textContent(element), block: true, language: language)
        case "code":
            guard attributesAllowed(element), element.children().isEmpty() else { return nil }
            return code(textContent(element), block: false)
        case "ul", "ol": return try list(element)
        case "table": return try table(element)
        case "input":
            // Only the leading checkbox of an understood list item may become
            // GFM syntax. Other inputs must retain their original semantics.
            return nil
        default: break
        }
        guard attributesAllowed(element), let content = try children(element, skipping: skipping) else { return nil }
        switch tag {
        case "p", "div": return "\n\n\(content)\n\n"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            return "\n\n\(String(repeating: "#", count: Int(tag.suffix(1)) ?? 1)) \(content)\n\n"
        case "strong", "b", "em", "i", "del", "s", "strike":
            let marker = ["strong", "b"].contains(tag) ? "**" : (["em", "i"].contains(tag) ? "*" : "~~")
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Markdown delimiters next to punctuation/whitespace can change meaning;
            // raw HTML is the standard inline representation in those cases.
            if content != trimmed { return try element.outerHtml() }
            return marker + content + marker
        case "br": return "  \n"
        case "hr": return "\n\n---\n\n"
        case "blockquote":
            return "\n\n" + content.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        case "span": return content
        default: return nil
        }
    }

    static func list(_ element: Element) throws -> String? {
        let ordered = element.tagNameNormal() == "ol"
        guard attributesAllowed(element, ordered ? ["start"] : []) else { return nil }
        let startString = try element.attr("start")
        guard startString.isEmpty || Int(startString) != nil else { return nil }
        let start = Int(startString) ?? 1
        var result: [String] = []
        for node in element.getChildNodes() {
            if let text = node as? TextNode, text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let item = node as? Element, item.tagNameNormal() == "li", attributesAllowed(item) else { return nil }
            let checkboxes = try item.select("input")
            guard checkboxes.count <= 1 else { return nil }
            var marker = ordered ? "\(start + result.count). " : "- "
            var skipped: Node?
            if let checkbox = checkboxes.first() {
                // Only a leading checkbox is an ordinary GFM task item.
                var meaningful = item.getChildNodes().first { !($0 is TextNode) || !textContent($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if let paragraph = meaningful as? Element, paragraph.tagNameNormal() == "p" {
                    meaningful = paragraph.getChildNodes().first { !($0 is TextNode) || !textContent($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                }
                guard meaningful === checkbox, !ordered else { return nil }
                guard attributesAllowed(checkbox, ["type", "checked", "disabled"]), try checkbox.attr("type").lowercased() == "checkbox" else { return nil }
                marker += checkbox.hasAttr("checked") ? "[x] " : "[ ] "
                skipped = checkbox
            }
            guard let content = try children(item, skipping: skipped) else { return nil }
            let lines = content.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard let first = lines.first else { continue }
            let indent = String(repeating: " ", count: ordered ? marker.count : 4)
            result.append(marker + first + lines.dropFirst().map { "\n" + indent + $0 }.joined())
        }
        return "\n\n" + result.joined(separator: "\n") + "\n\n"
    }

    static func table(_ element: Element) throws -> String? {
        guard attributesAllowed(element), try element.select("table").count == 1 else { return nil }
        // GFM has no caption, column layout, footer, or row-group semantics.
        // Preserve the whole table instead of silently flattening these parts.
        guard try element.select("caption,colgroup,col,tfoot").isEmpty(),
              try element.select("thead").count <= 1, try element.select("tbody").count <= 1 else { return nil }
        for descendant in try element.select("*").array() where descendant !== element {
            let tag = descendant.tagNameNormal()
            let allowed: Set<String> = (tag == "th" || tag == "td") ? ["align"] : []
            guard attributesAllowed(descendant, allowed) else { return nil }
        }
        let rows = try element.select("tr").array()
        guard let first = rows.first else { return nil }
        let headers = first.children().array()
        guard !headers.isEmpty, headers.allSatisfy({ $0.tagNameNormal() == "th" }) else { return nil }
        var lines: [String] = []
        var delimiters: [String] = []
        for header in headers {
            switch try header.attr("align").lowercased() {
            case "left": delimiters.append(":---")
            case "center": delimiters.append(":---:")
            case "right": delimiters.append("---:")
            case "": delimiters.append("---")
            default: return nil
            }
        }
        for (rowIndex, row) in rows.enumerated() {
            let cells = row.children().array()
            guard cells.count == headers.count else { return nil }
            var values: [String] = []
            for (index, cell) in cells.enumerated() {
                guard cell.tagNameNormal() == (rowIndex == 0 ? "th" : "td"), let content = try children(cell), !content.contains("\n") else { return nil }
                if rowIndex > 0 {
                    let align = try cell.attr("align").lowercased()
                    let headerAlign = try headers[index].attr("align").lowercased()
                    guard align.isEmpty || align == headerAlign else { return nil }
                }
                values.append(content)
            }
            lines.append("| " + values.joined(separator: " | ") + " |")
            if rowIndex == 0 { lines.append("| " + delimiters.joined(separator: " | ") + " |") }
        }
        return "\n\n" + lines.joined(separator: "\n") + "\n\n"
    }
}

private enum PreviewSanitizer {
    static let allowed: Set<String> = ["p", "div", "span", "h1", "h2", "h3", "h4", "h5", "h6", "strong", "b", "em", "i", "u", "s", "strike", "del", "sub", "sup", "blockquote", "ul", "ol", "li", "pre", "code", "br", "hr", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "colgroup", "col", "a", "img", "input", "details", "summary"]
    static let removed: Set<String> = ["script", "style", "iframe", "frame", "frameset", "object", "embed", "svg", "math", "form", "button", "textarea", "select", "option", "link", "meta", "base", "template", "noscript", "audio", "video", "source", "track"]
    static let void: Set<String> = ["br", "hr", "img", "input", "col"]

    static func safeURL(_ value: String, image: Bool) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !normalized.contains("\\") else { return false }
        if normalized.lowercased().hasPrefix("data:") {
            guard image else { return false }
            return ["data:image/png;base64,", "data:image/jpeg;base64,", "data:image/gif;base64,", "data:image/webp;base64,"].contains { normalized.lowercased().hasPrefix($0) }
        }
        if let colon = normalized.firstIndex(of: ":"), !normalized[..<colon].contains(where: { "/?#".contains($0) }) {
            let scheme = normalized[..<colon].lowercased()
            if scheme == "note-task", !image { return URLComponents(string: normalized)?.host.flatMap(Int.init).map { $0 > 0 } ?? false }
            return (image ? ["http", "https", "attachment"] : ["http", "https", "mailto", "tel", "attachment", "synology-note"]).contains(scheme)
        }
        return true
    }

    static func serialize(_ node: Node) -> String {
        if let text = node as? TextNode { return htmlEscape(text.getWholeText()) }
        guard let element = node as? Element else { return "" }
        let tag = element.tagNameNormal()
        guard !removed.contains(tag) else { return "" }
        let body = element.getChildNodes().map(serialize).joined()
        guard allowed.contains(tag) else { return body }
        if tag == "input", (try? element.attr("type").lowercased()) != "checkbox" { return "" }
        var attrs = ""
        for attribute in element.getAttributes()?.asList() ?? [] {
            let key = attribute.getKey().lowercased()
            let value = attribute.getValue()
            var keep = ["title", "class", "lang", "dir"].contains(key)
            if tag == "a", key == "href" { keep = safeURL(value, image: false) }
            if tag == "img", key == "src" { keep = safeURL(value, image: true) }
            if tag == "img", key == "alt" { keep = true }
            if ["width", "height", "colspan", "rowspan", "start", "span"].contains(key) {
                keep = Int(value).map { $0 >= 0 && $0 <= 100_000 } ?? false
            }
            if key == "align" { keep = ["left", "right", "center"].contains(value.lowercased()) }
            if tag == "input", key == "checked" { keep = true }
            if key == "data-source-line" { keep = Int(value).map { $0 > 0 } ?? false }
            if tag == "input", key == "data-md-task" { keep = Int(value).map { $0 > 0 } ?? false }
            if keep { attrs += " \(key)=\"\(htmlEscape(value))\"" }
        }
        if tag == "input" { attrs += " type=\"checkbox\" disabled" }
        if tag == "a" { attrs += " rel=\"noopener noreferrer\"" }
        return "<\(tag)\(attrs)>" + (void.contains(tag) ? "" : body + "</\(tag)>")
    }

}
