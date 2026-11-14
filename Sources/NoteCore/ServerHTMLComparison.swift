import Foundation
import SwiftSoup

/// Limited readback tolerance for generated code blocks. The source attachment
/// still hashes the exact HTML returned by NAS; arbitrary HTML is never relaxed.
enum ServerHTMLComparison {
    private enum Part { case html(String), code(String, String?) }
    static func matches(_ expected: String, _ actual: String, allowsCodeNormalization: Bool) -> Bool {
        if expected == actual { return true }
        guard allowsCodeNormalization, let lhs = parts(expected), let rhs = parts(actual), lhs.count == rhs.count else { return false }
        var comparedCode = false
        for (left, right) in zip(lhs, rhs) {
            switch (left, right) {
            case (.html(let a), .html(let b)): if a != b { return false }
            case (.code(let a, let language), .code(let b, let otherLanguage)):
                guard a == b, otherLanguage == nil || language == otherLanguage else { return false }
                comparedCode = true
            default: return false
            }
        }
        return comparedCode
    }
    private static func parts(_ html: String) -> [Part]? {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            document.outputSettings().prettyPrint(pretty: false)
            var cursor = html.startIndex, result: [Part] = []
            for pre in try document.select("pre").array() {
                guard pre.getAttributes()?.size() == 0 else { return nil }
                let children = pre.getChildNodes()
                let textNodes: [Node], language: String?
                if children.count == 1, let code = children[0] as? Element, code.tagNameNormal() == "code" {
                    let attributes = code.getAttributes()?.asList() ?? []
                    guard attributes.isEmpty || (attributes.count == 1 && attributes[0].getKey() == "class" && attributes[0].getValue().hasPrefix("language-") && !attributes[0].getValue().contains(where: { $0.isWhitespace })) else { return nil }
                    textNodes = code.getChildNodes(); language = attributes.first?.getValue()
                } else { textNodes = children; language = nil }
                guard textNodes.allSatisfy({ $0 is TextNode }) else { return nil }
                let raw = try pre.outerHtml()
                guard let range = html.range(of: raw, range: cursor..<html.endIndex) else { return nil }
                result.append(.html(String(html[cursor..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)))
                let code = textNodes.compactMap { ($0 as? TextNode)?.getWholeText() }.joined().replacingOccurrences(of: "\r\n", with: "\n")
                result.append(.code(code, language))
                cursor = range.upperBound
            }
            result.append(.html(String(html[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)))
            return result
        } catch { return nil }
    }
}
