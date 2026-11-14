import Foundation
import Markdown

/// Protect TeX before CommonMark consumes escapes, emphasis, table pipes or HTML.
/// Only the preview uses this intermediate source; stored Markdown stays intact.
struct MathPreviewSource {
    struct Formula {
        let token: String
        let tex: String
        let display: Bool
        let source: String
    }
    let markdown: String
    let formulas: [Formula]

    init(_ source: String) {
        let bytes = Array(source.utf8)
        var lineStarts = [0]
        for i in bytes.indices {
            if bytes[i] == 10 || (bytes[i] == 13 && (i + 1 == bytes.count || bytes[i + 1] != 10)) {
                lineStarts.append(i + 1)
            }
        }
        func byteRange(_ node: Markup) -> Range<Int>? {
            guard let range = node.range,
                  range.lowerBound.line > 0, range.upperBound.line > 0,
                  range.lowerBound.line <= lineStarts.count, range.upperBound.line <= lineStarts.count else { return nil }
            let lower = lineStarts[range.lowerBound.line - 1] + range.lowerBound.column - 1
            let upper = lineStarts[range.upperBound.line - 1] + range.upperBound.column - 1
            guard lower >= 0, upper >= lower, upper <= bytes.count else { return nil }
            return lower..<upper
        }
        var allowed = Array(repeating: false, count: bytes.count)
        var protected = Array(repeating: false, count: bytes.count)
        var blockProtected = Array(repeating: false, count: bytes.count)
        var inlineHTMLStarts: Set<Int> = []
        var referenceTails: [Int: (end: Int, text: String)] = [:]
        func protect(_ range: Range<Int>) {
            for i in range { protected[i] = true }
        }
        func walk(_ node: Markup) {
            if let range = byteRange(node) {
                if node is Paragraph || node is Heading || node is Markdown.Table {
                    for i in range { allowed[i] = true }
                }
                if node is CodeBlock || node is InlineCode || node is HTMLBlock || node is InlineHTML || node is Markdown.Image {
                    protect(range)
                    if node is InlineHTML { inlineHTMLStarts.insert(range.lowerBound) }
                    if node is CodeBlock || node is InlineCode || node is HTMLBlock {
                        for i in range { blockProtected[i] = true }
                    }
                    return
                }
                if node is Markdown.Link {
                    // Permit formulas in link labels, never in destinations or titles.
                    let children = Array(node.children)
                    if let first = children.first.flatMap(byteRange), let last = children.last.flatMap(byteRange) {
                        protect(range.lowerBound..<first.lowerBound)
                        protect(last.upperBound..<range.upperBound)
                        // Make shortcut/collapsed references explicit before masking
                        // their visible label, keeping the original reference ID.
                        if bytes[range.lowerBound] == 91,
                           let close = (last.upperBound..<range.upperBound).first(where: { bytes[$0] == 93 }) {
                            let tail = String(decoding: bytes[(close + 1)..<range.upperBound], as: UTF8.self)
                            if tail.isEmpty || tail == "[]" {
                                let label = String(decoding: bytes[(range.lowerBound + 1)..<close], as: UTF8.self)
                                    .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
                                referenceTails[close + 1] = (range.upperBound, "[\(label)]")
                            }
                        }
                    } else { protect(range) }
                }
            }
            for child in node.children { walk(child) }
        }
        walk(Markdown.Document(parsing: source, options: [.disableSmartOpts]))
        // Inline raw HTML has separate opening/closing AST nodes. Protect the
        // complete contents of literal/code elements when a formula starts there.
        let literalHTML = try? NSRegularExpression(pattern: #"<(code|pre|script|style|textarea)\b[^>]*>.*?(?:</\1\s*>|\z)"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        for match in literalHTML?.matches(in: source, range: NSRange(source.startIndex..., in: source)) ?? [] {
            if let range = Range(match.range, in: source) {
                let lower = source[..<range.lowerBound].utf8.count
                if inlineHTMLStarts.contains(lower) { protect(lower..<(lower + source[range].utf8.count)) }
            }
        }
        func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
        func escaped(_ index: Int) -> Bool {
            var i = index
            while i > 0, bytes[i - 1] == 92 { i -= 1 }
            return (index - i) % 2 == 1
        }
        func matches(_ delimiter: [UInt8], at i: Int) -> Bool {
            i + delimiter.count <= bytes.count && bytes[i..<(i + delimiter.count)].elementsEqual(delimiter)
        }
        let delimiters: [(open: [UInt8], close: [UInt8], display: Bool)] = [
            ([36, 36], [36, 36], true),
            ([92, 91], [92, 93], true),
            ([92, 40], [92, 41], false),
            ([36], [36], false)
        ]
        let prefix = "SynologyMath" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var output: [UInt8] = []
        var formulas: [Formula] = []
        var failedSearchUntil = Array(repeating: 0, count: delimiters.count)
        var cursor = 0
        var currentLine = 0
        var skippedDollar: Int?
        while cursor < bytes.count {
            while currentLine + 1 < lineStarts.count, lineStarts[currentLine + 1] <= cursor { currentLine += 1 }
            if let tail = referenceTails.removeValue(forKey: cursor) {
                output += tail.text.utf8
                if tail.end > cursor { cursor = tail.end; continue }
            }
            var found: (end: Int, tex: Range<Int>, display: Bool)?
            let secondDollar = cursor == skippedDollar
            if allowed[cursor], !protected[cursor], !escaped(cursor), !secondDollar {
                for (delimiterIndex, delimiter) in delimiters.enumerated() where matches(delimiter.open, at: cursor) {
                    if cursor < failedSearchUntil[delimiterIndex] {
                        if delimiter.open == [36, 36] { skippedDollar = cursor + 1; break }
                        continue
                    }
                    let start = cursor + delimiter.open.count
                    let singleDollar = delimiter.open == [36]
                    if singleDollar, start == bytes.count || whitespace(bytes[start]) || matches([36], at: start) { continue }
                    var end = start
                    while end < bytes.count {
                        if blockProtected[end] || (!allowed[end] && !whitespace(bytes[end])) { break }
                        if !delimiter.display, bytes[end] == 10 || bytes[end] == 13 { break }
                        if matches(delimiter.close, at: end), !escaped(end) {
                            let after = end + delimiter.close.count
                            let closingIsAllowed = after <= bytes.count && (end..<after).allSatisfy { !blockProtected[$0] && allowed[$0] }
                            let currency = singleDollar && (end == start || whitespace(bytes[end - 1]) || (after < bytes.count && (48...57).contains(bytes[after])))
                            if closingIsAllowed, !currency {
                                found = (after, start..<end, delimiter.display)
                                break
                            }
                        }
                        end += 1
                    }
                    if found == nil {
                        failedSearchUntil[delimiterIndex] = end
                        if delimiter.open == [36, 36] { skippedDollar = cursor + 1 }
                    }
                    // An unmatched $$ must not be reconsidered as a single $.
                    if found != nil || delimiter.open == [36, 36] { break }
                }
            }
            if let found {
                let token = prefix + "F\(formulas.count)End"
                let lineStart = lineStarts[currentLine]
                let quoteDepth = bytes[lineStart..<cursor].prefix(while: { [9, 32, 62].contains($0) }).filter { $0 == 62 }.count
                func withoutQuotePrefix(_ line: Substring) -> (prefix: String, body: String) {
                    var rest = line[...]
                    for _ in 0..<quoteDepth {
                        let candidate = rest.drop(while: { $0 == " " || $0 == "\t" })
                        guard candidate.first == ">" else { return ("", String(line)) }
                        rest = candidate.dropFirst()
                        if rest.first == " " || rest.first == "\t" { rest = rest.dropFirst() }
                    }
                    return (String(line[..<rest.startIndex]), String(rest))
                }
                let raw = String(decoding: bytes[found.tex], as: UTF8.self)
                let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
                let tex = lines.enumerated().map { $0.offset == 0 ? String($0.element) : withoutQuotePrefix($0.element).body }.joined(separator: "\n")
                let original = String(decoding: bytes[cursor..<found.end], as: UTF8.self)
                formulas.append(Formula(token: token, tex: tex, display: found.display, source: original))
                output += token.utf8
                // Retain source line numbers used by interactive task checkboxes.
                let matched = String(decoding: bytes[cursor..<found.end], as: UTF8.self)
                for line in matched.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
                    output.append(10)
                    output += withoutQuotePrefix(line).prefix.utf8
                }
                // Bare CR line endings must retain their line count too.
                if !matched.contains("\n") { output += matched.utf8.filter { $0 == 13 } }
                cursor = found.end
            } else {
                output.append(bytes[cursor])
                cursor += 1
            }
        }
        if let tail = referenceTails[bytes.count] { output += tail.text.utf8 }
        markdown = String(decoding: output, as: UTF8.self)
        self.formulas = formulas
    }

    func restoringFormulas(in html: String) -> String {
        formulas.reduce(html) { result, formula in
            let tex = formula.tex.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let mode = formula.display ? "display" : "inline"
            return result.replacingOccurrences(of: formula.token, with: "<span class=\"note-math note-math-\(mode)\">\(tex)</span>")
        }
    }

    func restoringMarkdown(in text: String) -> String {
        formulas.reduce(text) { $0.replacingOccurrences(of: $1.token, with: $1.source) }
    }

    func restoringSource(in html: String) -> String {
        formulas.reduce(html) { result, formula in
            let value = formula.source.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
            return result.replacingOccurrences(of: formula.token, with: value)
        }
    }
}
