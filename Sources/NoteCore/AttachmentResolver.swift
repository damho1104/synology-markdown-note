import Foundation
import SwiftSoup

public enum AttachmentResolver {
    /// Resolves a preview copy only. Original server HTML and opaque blocks stay unchanged.
    public static func previewHTML(_ html: String, attachments: [NoteAttachment]) -> String {
        guard let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body() else { return "" }
        // Reconstruct this preview copy: the parser's exact source-slice mode
        // can retain the old img markup after attributes are rewritten.
        document.outputSettings().prettyPrint(pretty: true)
        for element in (try? body.select("img, a").array()) ?? [] {
            let attribute = element.tagName() == "a" ? "href" : "src"
            let value = (try? element.attr(attribute)) ?? ""
            var candidates = [(try? element.attr("ref")) ?? "", (try? element.attr("content_id")) ?? ""]
            if let components = URLComponents(string: value) { candidates += (components.queryItems ?? []).filter { ["file_id", "ref", "content_id"].contains($0.name) }.compactMap(\.value) }
            if let asset = attachments.first(where: { attachment in
                candidates.contains(where: { !$0.isEmpty && ($0 == attachment.remoteID || $0 == attachment.remoteReference || $0 == attachment.name) })
            }) { try? element.attr(attribute, asset.reference) }
        }
        return (try? body.html()) ?? ""
    }
}
