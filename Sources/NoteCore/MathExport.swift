import Foundation
import CryptoKit
import SwiftSoup

public struct MathFormula: Codable, Hashable, Sendable {
    public let key: String
    public let tex: String
    public let display: Bool
    public init(tex: String, display: Bool) {
        self.tex = tex; self.display = display
        key = SHA256.hash(data: Data(("math-png-v1\n" + String(display) + "\n" + tex).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public struct RenderedMathImage: Sendable {
    public let key: String
    public let data: Data
    public let width: Double
    public let height: Double
    public init(key: String, data: Data, width: Double, height: Double) {
        self.key = key; self.data = data; self.width = width; self.height = height
    }
}

public protocol MathImageRendering: Sendable {
    func render(_ formulas: [MathFormula]) async throws -> [RenderedMathImage]
}

public struct MathAttachmentMetadata: Codable, Hashable, Sendable {
    public var key: String
    public var width: Double
    public var height: Double
    public init(key: String, width: Double, height: Double) {
        self.key = key; self.width = width; self.height = height
    }
    var isValid: Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && width.isFinite && height.isFinite && width > 0 && height > 0 && width <= 8192 && height <= 8192
    }
}

public enum MathExport {
    public static func formulas(in markdown: String, blocks: [PreservedBlock] = []) -> [MathFormula] {
        var keys: Set<String> = []
        return MathPreviewSource(markdown).formulas.compactMap {
            let formula = MathFormula(tex: $0.tex, display: $0.display)
            return keys.insert(formula.key).inserted ? formula : nil
        }
    }

    /// Render only app-owned math markers to ordinary image attachments. Neither
    /// TeX source nor code blocks are sent through a JavaScript-dependent format.
    public static func html(markdown: String, blocks: [PreservedBlock], attachments: [NoteAttachment]) throws -> String {
        let formulas = formulas(in: markdown, blocks: blocks)
        guard !formulas.isEmpty else { return MarkdownPipeline.render(markdown, blocks: blocks) }
        // Keep opaque original HTML outside the editing DOM. Only newly
        // generated math spans are replaced; other bytes stay untouched.
        let namespace = UUID().uuidString
        let protected = blocks.map { PreservedBlock(id: $0.id, html: "<!--math-export-\(namespace)-\($0.id)-->", label: $0.label) }
        var html = MarkdownPipeline.renderForMathExport(markdown, blocks: protected)
        let document = try SwiftSoup.parseBodyFragment(html)
        document.outputSettings().prettyPrint(pretty: false)
        for element in try document.select("span.note-math").array() {
            let formula = MathFormula(tex: try element.text(trimAndNormaliseWhitespace: false),
                                      display: element.hasClass("note-math-display"))
            guard formulas.contains(where: { $0.key == formula.key }) else { continue }
            let matches = attachments.filter { $0.generatedMath?.key == formula.key }
            guard matches.count == 1, let asset = matches.first, let metadata = asset.generatedMath,
                  metadata.width.isFinite, metadata.height.isFinite,
                  metadata.width > 0, metadata.height > 0, metadata.width <= 8192, metadata.height <= 8192 else {
                throw RepositoryError(message: coreText("Could not prepare a math image attachment. The source was kept for retry."))
            }
            let image = Element(try Tag.valueOf("img"), "")
            try image.attr("src", asset.reference)
            try image.attr("alt", (formula.display ? "$$" : "$") + formula.tex + (formula.display ? "$$" : "$"))
            try image.attr("width", String(Int(ceil(metadata.width))))
            try image.attr("height", String(Int(ceil(metadata.height))))
            try image.attr("style", formula.display ? "display: block; max-width: 100%;" : "vertical-align: middle; max-width: 100%;")
            let original = try element.outerHtml()
            guard let range = html.range(of: original) else { throw SyncError.verificationFailed }
            html.replaceSubrange(range, with: try image.outerHtml())
        }
        for block in blocks { html = html.replacingOccurrences(of: "<!--math-export-\(namespace)-\(block.id)-->", with: block.html) }
        return html
    }
}
