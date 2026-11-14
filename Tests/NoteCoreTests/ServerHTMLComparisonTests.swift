import Testing
@testable import NoteCore

@Suite struct ServerHTMLComparisonTests {
    @Test func permitsOnlyEquivalentPlainCodeAndPreservesIndentationAndArrows() {
        let original = "<pre><code class=\"language-mermaid\">A --&gt; B\n  B --&gt; C\n</code></pre>\n"
        let normalized = "<pre>A --&#62; B\n  B --&#62; C\n</pre>"
        #expect(ServerHTMLComparison.matches(original, normalized, allowsCodeNormalization: true))
        #expect(!ServerHTMLComparison.matches(original, normalized.replacingOccurrences(of: "  B", with: "B"), allowsCodeNormalization: true))
        #expect(!ServerHTMLComparison.matches(original, normalized.replacingOccurrences(of: " C", with: " D"), allowsCodeNormalization: true))
        #expect(!ServerHTMLComparison.matches(original, normalized, allowsCodeNormalization: false))
    }
    @Test func changesToLinksStylesAndNonCodeHTMLRemainFailures() {
        let code = "<pre><code class=\"language-mermaid\">A--&gt;B\n</code></pre>"
        let html = "<p style='white-space:pre'>A  B</p><a href='https://example.test/old'>link</a>" + code
        #expect(!ServerHTMLComparison.matches(html, html.replacingOccurrences(of: "A  B", with: "A B"), allowsCodeNormalization: true))
        #expect(!ServerHTMLComparison.matches(html, html.replacingOccurrences(of: "/old", with: "/new"), allowsCodeNormalization: true))
        #expect(!ServerHTMLComparison.matches(html, html.replacingOccurrences(of: "white-space:pre", with: "white-space:normal"), allowsCodeNormalization: true))
    }
}
