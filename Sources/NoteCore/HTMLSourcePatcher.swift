import Foundation

/// Locates opening attachment tags in the original UTF-8 source. This scanner
/// only finds byte boundaries; SwiftSoup remains the authority for attributes.
/// Comments and literal script/style/text containers never become candidates.
enum HTMLSourcePatcher {
    struct TagSlice { let name: String; let range: Range<Int>; let html: String }
    static func attachmentTags(in html: String) -> [TagSlice] {
        let bytes = Array(html.utf8)
        let lower = bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
        func matches(_ value: String, _ index: Int) -> Bool {
            let pattern = Array(value.utf8)
            return index + pattern.count <= bytes.count && lower[index..<(index + pattern.count)].elementsEqual(pattern)
        }
        func letter(_ value: UInt8) -> Bool { (97...122).contains(value) || (48...57).contains(value) || value == 45 || value == 58 }
        var result: [TagSlice] = [], cursor = 0
        while cursor < bytes.count {
            guard bytes[cursor] == 60 else { cursor += 1; continue }
            let start = cursor
            if matches("<!--", cursor) {
                cursor += 4
                while cursor < bytes.count && !matches("-->", cursor) { cursor += 1 }
                cursor = min(bytes.count, cursor + 3); continue
            }
            if matches("<![cdata[", cursor) {
                cursor += 9
                while cursor < bytes.count && !matches("]]>", cursor) { cursor += 1 }
                cursor = min(bytes.count, cursor + 3); continue
            }
            if cursor + 1 < bytes.count && [33, 63].contains(bytes[cursor + 1]) {
                cursor += 2
                var quote: UInt8?, brackets = 0
                while cursor < bytes.count {
                    let byte = bytes[cursor]
                    if let active = quote { if byte == active { quote = nil } }
                    else if byte == 34 || byte == 39 { quote = byte }
                    else if byte == 91 { brackets += 1 }
                    else if byte == 93 { brackets = max(0, brackets - 1) }
                    else if byte == 62 && brackets == 0 { break }
                    cursor += 1
                }
                cursor = min(bytes.count, cursor + 1); continue
            }
            cursor += 1
            let closing = cursor < bytes.count && bytes[cursor] == 47
            if closing { cursor += 1 }
            let nameStart = cursor
            while cursor < bytes.count && letter(lower[cursor]) { cursor += 1 }
            let name = String(decoding: lower[nameStart..<cursor], as: UTF8.self)
            guard !name.isEmpty else { continue }
            var quote: UInt8?
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if let active = quote { if byte == active { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
                cursor += 1
            }
            guard cursor < bytes.count else { break }
            cursor += 1
            if !closing && ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"].contains(name) {
                while cursor < bytes.count {
                    let end = cursor + name.utf8.count + 2
                    if matches("</" + name, cursor), end < bytes.count, [9, 10, 13, 32, 62].contains(bytes[end]) { break }
                    cursor += 1
                }
                continue
            }
            if !closing && ["img", "a"].contains(name) {
                result.append(TagSlice(name: name, range: start..<cursor, html: String(decoding: bytes[start..<cursor], as: UTF8.self)))
            }
        }
        return result
    }

    static func replacing(in html: String, replacements: [(Range<Int>, String)]) throws -> String {
        let bytes = Array(html.utf8)
        var output: [UInt8] = [], cursor = 0
        for (range, value) in replacements.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            guard range.lowerBound >= cursor, range.upperBound <= bytes.count else { throw SyncError.verificationFailed }
            output += bytes[cursor..<range.lowerBound]; output += value.utf8; cursor = range.upperBound
        }
        output += bytes[cursor...]
        return String(decoding: output, as: UTF8.self)
    }
}
