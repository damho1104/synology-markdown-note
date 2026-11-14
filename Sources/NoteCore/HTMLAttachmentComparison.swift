import Foundation
import SwiftSoup

/// The only intentional body rewrite in original mode is a verified local
/// attachment URL becoming a NAS ref. All other content and attributes matter.
enum HTMLAttachmentComparison {
    static func matches(_ expected: String, _ actual: String, expectedAssets: [NoteAttachment], actualAssets: [NoteAttachment]) -> Bool {
        if expected == actual { return true }
        guard expected.lowercased().contains("attachment://") else { return false }
        do { return try canonical(expected, assets: expectedAssets) == canonical(actual, assets: actualAssets) }
        catch { return false }
    }

    private static func canonical(_ html: String, assets: [NoteAttachment]) throws -> String {
        let dom = try SwiftSoup.parseBodyFragment(html)
        for element in try dom.select("img,a").array() {
            let attribute = element.tagNameNormal() == "img" ? "src" : "href"
            let value = try element.attr(attribute)
            var candidates = [try element.attr("ref"), try element.attr("content_id")].filter { !$0.isEmpty }
            var localID: UUID?
            if let url = URLComponents(string: value) {
                if url.scheme == "attachment" { localID = url.host.flatMap(UUID.init(uuidString:)) }
                candidates += (url.queryItems ?? []).filter { ["file_id", "ref", "content_id"].contains($0.name) }.compactMap(\.value)
            }
            let matches = assets.filter { asset in
                localID == asset.id || candidates.contains { $0 == asset.remoteID || $0 == asset.remoteReference }
            }
            guard matches.count <= 1 else { throw SyncError.verificationFailed }
            if let asset = matches.first {
                let identity = asset.remoteReference.flatMap(UUID.init(uuidString:))?.uuidString ?? asset.remoteID ?? asset.id.uuidString
                try element.attr(attribute, "verified-attachment:" + identity)
                try element.removeAttr("ref"); try element.removeAttr("content_id")
            } else if localID != nil { throw SyncError.verificationFailed }
        }
        func serialize(_ node: Node) throws -> String {
            if let text = node as? TextNode { return "text:" + String(reflecting: text.getWholeText()) }
            guard let element = node as? Element else { return try node.outerHtml() }
            let attributes = (element.getAttributes()?.asList() ?? []).map { [$0.getKey(), $0.getValue()] }.sorted { $0[0] < $1[0] }
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: attributes), as: UTF8.self)
            return "<" + element.tagNameNormal() + encoded + ">" + (try node.getChildNodes().map(serialize).joined()) + "</>"
        }
        return try (dom.body()?.getChildNodes() ?? []).map(serialize).joined()
    }
}
