import Foundation
import SwiftSoup

public enum MarkdownEditing {
    public static func toggleTask(_ source: String, line: Int) -> String {
        guard line > 0 else { return source }
        let text = source as NSString
        var offset = 0, number = 1
        while offset < text.length {
            let range = text.lineRange(for: NSRange(location: offset, length: 0))
            if number == line {
                let value = text.substring(with: range)
                guard let regex = try? NSRegularExpression(pattern: "^\\s*(?:[-*+] |[0-9]+[.)] )\\[([ xX])\\]"), let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: value.utf16.count)) else { return source }
                let check = match.range(at: 1)
                let result = NSMutableString(string: source)
                result.replaceCharacters(in: NSRange(location: range.location + check.location, length: 1), with: (value as NSString).substring(with: check) == " " ? "x" : " ")
                return result as String
            }
            offset = range.location + range.length; number += 1
        }
        return source
    }

    /// Preview links allow checkbox editing without running JavaScript in note content.
    public static func interactivePreview(_ html: String) -> String {
        guard let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body() else { return html }
        document.outputSettings().prettyPrint(pretty: false)
        for input in (try? body.select("input[data-md-task]").array()) ?? [] {
            guard let value = try? input.attr("data-md-task"), let line = Int(value), line > 0 else { continue }
            let checked = input.hasAttr("checked")
            let label = htmlEscape(checked ? coreText("Uncheck") : coreText("Check"))
            try? input.before("<a class=\"task-toggle\" href=\"note-task://\(line)\" aria-label=\"\(label)\">\(checked ? "☑" : "☐")</a>")
            try? input.remove()
            if let parent = input.parent() { try? parent.addClass("task-item") }
        }
        return (try? body.html()) ?? html
    }
}
