import Foundation
import Testing
import SwiftSoup
import WebKit
@testable import NoteCore
@testable import SynologyNote

@Suite struct MathPreviewTests {
    @MainActor @Test func frontMatterDetailsToggleInActualWebPreview() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 350), configuration: configuration)
        let loader = MathPageLoader()
        web.navigationDelegate = loader
        let markdown = """
        ---
        type: daily
        session_count: 34
        ---

        # 📅 2026-05-27 (수)

        **본문 강조**

        <!-- wiki:keep -->
        """
        try await loader.load(MarkdownPipeline.previewPage(MarkdownPipeline.renderForPreview(markdown)), in: web)
        #expect(try await mathEvaluate("document.querySelector('details.note-frontmatter').open", in: web) as? Bool == false)
        #expect(try await mathEvaluate("document.querySelector('h1').textContent", in: web) as? String == "📅 2026-05-27 (수)")
        #expect(try await mathEvaluate("document.querySelector('strong').textContent", in: web) as? String == "본문 강조")
        #expect(try await mathEvaluate("document.body.innerHTML.includes('wiki:keep')", in: web) as? Bool == false)
        _ = try await mathEvaluate("document.querySelector('details > summary').click()", in: web)
        #expect(try await mathEvaluate("document.querySelector('details.note-frontmatter').open", in: web) as? Bool == true)
        #expect(try await mathEvaluate("document.querySelector('details pre code').textContent.includes('session_count: 34')", in: web) as? Bool == true)
    }

    @Test func preservesTeXBeforeMarkdownParsing() throws {
        let source = #"한글 $x_i + y_j < z & \text{a_b}$, \(\frac{a}{b}\)."#
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.renderForPreview(source))
        let math = try dom.select(".note-math-inline").array()
        #expect(math.count == 2)
        #expect(try math.first?.text() == #"x_i + y_j < z & \text{a_b}"#)
        #expect(try math.last?.text() == #"\frac{a}{b}"#)
        #expect(try dom.select("em").isEmpty())
    }

    @Test func supportsMultilineDisplayMathAndKeepsTaskLineNumbers() throws {
        let source = #"""
        $$
        \begin{aligned}
        x_i &= y_j \\
        a &= \frac{1}{2}
        \end{aligned}
        $$

        \[\sum_{i=1}^n i\]

        - [ ] 완료
        """#
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.renderForPreview(source))
        #expect(try dom.select(".note-math-display").count == 2)
        #expect(try dom.select(".note-math-display").first()?.text().contains(#"x_i &= y_j \\"#) == true)
        #expect(try dom.select("input").attr("data-md-task") == "10")
    }

    @Test func ignoresCodeLinksImagesRawHTMLAndEscapedDollars() throws {
        let source = #"""
        `$x$` and \$5 and $10 and $20.

        ```latex
        $$\frac{a}{b}$$
        ```

            $indented$

        [link](https://example.test/$x$) ![image $x$](attachment://42)

        <div title="$attribute$">$html$</div>

        $real$
        """#
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.renderForPreview(source))
        #expect(try dom.select(".note-math").count == 1)
        #expect(try dom.select(".note-math").text() == "real")
        #expect(try dom.select("a").attr("href") == "https://example.test/$x$")
        #expect(try dom.select("img").attr("alt") == "image $x$")
        #expect(try dom.select("code").first()?.text() == "$x$")
    }

    @Test func supportsHeadingsListsTablesAndLinkLabels() throws {
        let source = #"""
        # 결과 $x_i$

        - $a_b$

        | 값 |
        | --- |
        | $\frac{a}{b}$ |

        [$x$](https://example.test)
        """#
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.renderForPreview(source))
        #expect(try dom.select("h1 .note-math, li .note-math, td .note-math, a .note-math").count == 4)
    }

    @Test func unmatchedDelimitersAndServerHTMLRemainUnchanged() {
        for source in [#"한글 $x"#, #"한글 \[x"#, #"비용 \$5"#, "보통 **강조**", "$$x$"] {
            #expect(MarkdownPipeline.renderForPreview(source) == MarkdownPipeline.render(source))
        }
        let source = #"$x_i$"#
        #expect(!MarkdownPipeline.render(source).contains("note-math"))
        let block = PreservedBlock(id: "original", html: "<div>$original$</div>", label: "원본")
        let markdown = source + "\n\n" + MarkdownPipeline.token(for: block)
        #expect(MarkdownPipeline.renderForPreview(markdown, blocks: [block]).contains(block.html))
        #expect(MarkdownPipeline.renderForPreview("$x$\n\n:::synology-block missing :::").isEmpty)
    }

    @Test func preservesVerticalBarsInsideTableMath() throws {
        let source = #"""
        | 수식 | 값 |
        | --- | --- |
        | $\lvert x \rvert = |x|$ | 1 |
        """#
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.renderForPreview(source))
        #expect(try dom.select("tbody td").count == 2)
        #expect(try dom.select(".note-math").text() == #"\lvert x \rvert = |x|"#)
    }

    @Test func mathTakesPriorityOverInlineMarkdownAndHTML() throws {
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.renderForPreview(#"$a<b>c$ and $[x](y)$"#))
        #expect(try dom.select(".note-math").eachText() == ["a<b>c", "[x](y)"])
        #expect(try dom.select("b,a").isEmpty())
    }

    @Test func rawHTMLCodeRemainsLiteralAndReferenceLinksKeepTheirDestination() throws {
        let source = #"""
        <code>$literal$</code> and <pre>$alsoLiteral$</pre>

        [$x$] and [$y$][] and [$z$][destination]

        [$x$]: https://example.test/x
        [$y$]: https://example.test/y
        [destination]: https://example.test/z
        """#
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.renderForPreview(source))
        #expect(try dom.select("code,pre").eachText() == ["$literal$", "$alsoLiteral$"])
        #expect(try dom.select("a .note-math").count == 3)
        #expect(try dom.select("a").array().map { try $0.attr("href") } == ["https://example.test/x", "https://example.test/y", "https://example.test/z"])
    }

    @Test func stripsQuotePrefixesAndKeepsFollowingTaskLineNumbers() throws {
        let source = "> $$\n> x_i + y_j\n> $$\n>\n> - 목록\n\n- [ ] 작업"
        let html = MarkdownPipeline.renderForPreview(source)
        let dom = try SwiftSoup.parseBodyFragment(html)
        #expect(try dom.select("blockquote .note-math").text() == "x_i + y_j")
        #expect(try dom.select("blockquote li").text() == "목록")
        #expect(try dom.select("input").attr("data-md-task") == "7")
    }

    @Test func codeExamplesOfRawHTMLDoNotHideFollowingMath() throws {
        let source = "```html\n<code>\n```\n\n$x$"
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.renderForPreview(source))
        #expect(try dom.select(".note-math").text() == "x")
        #expect(try dom.select("code").text() == "<code>")
    }

    @Test func adjacentFormulasRenderAndUnclosedMathCannotConsumeInlineCode() throws {
        let adjacent = try SwiftSoup.parseBodyFragment(MarkdownPipeline.renderForPreview("$a$$b$"))
        #expect(try adjacent.select(".note-math").eachText() == ["a", "b"])
        let source = "$a `$b$`"
        #expect(MarkdownPipeline.renderForPreview(source) == MarkdownPipeline.render(source))
    }

    @MainActor @Test func rendersOfflineWithFontsAndPageScriptsDisabled() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let loader = MathPageLoader()
        web.navigationDelegate = loader
        let source = #"""
        # LaTeX 수식 미리보기

        질량과 에너지: $E=mc^2$, 분수: \(\frac{a}{b}\).

        $$\int_0^\infty e^{-x}\,dx = 1$$

        \[\begin{pmatrix}a & b \\ c & d\end{pmatrix}\]

        잘못된 수식: $\frac{$

        `$code$`

        ```mermaid
        graph LR
        A[입력] --> B[미리보기]
        ```
        """#
        let page = MarkdownPipeline.previewPage(MarkdownPipeline.renderForPreview(source))
        try await loader.load(page, in: web)
        _ = try await mathEvaluate(try MathPreviewRuntime.renderJavaScript(), in: web)
        #expect(try await mathEvaluate("document.querySelectorAll('.note-math .katex').length", in: web) as? Int == 4)
        #expect(try await mathEvaluate("document.querySelectorAll('.katex-display').length", in: web) as? Int == 2)
        #expect(try await mathEvaluate("document.querySelectorAll('.katex math').length", in: web) as? Int == 4)
        #expect(try await mathEvaluate("document.querySelector('code').textContent", in: web) as? String == "$code$")
        #expect(try await mathEvaluate("document.querySelector('.note-math-error').textContent", in: web) as? String == #"\frac{"#)
        // Math must coexist with the existing separately injected Mermaid runtime.
        _ = try await mathEvaluate(try MermaidPreviewRuntime.libraryJavaScript(), in: web)
        _ = try await mathEvaluate(MermaidPreviewRuntime.bootstrapJavaScript(), in: web)
        for _ in 0..<100 {
            if try await mathEvaluate("document.querySelectorAll('.mermaid svg').length", in: web) as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await mathEvaluate("document.querySelectorAll('.mermaid svg').length", in: web) as? Int == 1)
        // Font readiness and nonzero glyph geometry prove that offline CSS/fonts loaded.
        for _ in 0..<100 {
            if try await mathEvaluate("document.fonts.status", in: web) as? String == "loaded" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await mathEvaluate("document.fonts.check('16px KaTeX_Main')", in: web) as? Bool == true)
        #expect(try await mathEvaluate("document.querySelector('.katex-html').getBoundingClientRect().height > 10", in: web) as? Bool == true)
        _ = try await mathEvaluate(try MathPreviewRuntime.renderJavaScript(), in: web)
        #expect(try await mathEvaluate("document.querySelectorAll('.note-math .katex').length", in: web) as? Int == 4)
        if ProcessInfo.processInfo.environment["SYNOLOGY_NOTE_MATH_SNAPSHOT"] != nil {
            let image = try await web.takeSnapshot(configuration: nil)
            try image.tiffRepresentation?.write(to: URL(fileURLWithPath: "/tmp/synology-note-math-preview.tiff"))
        }
    }

    @MainActor @Test func blocksUntrustedTeXCommandsAndPageJavaScript() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        let loader = MathPageLoader()
        web.navigationDelegate = loader
        let source = #"""
        $\href{javascript:alert(1)}{click}$

        $\includegraphics{https://example.test/image.png}$

        $<script>window.evil=1</script>$
        """#
        try await loader.load(MarkdownPipeline.previewPage(MarkdownPipeline.renderForPreview(source)), in: web)
        _ = try await mathEvaluate(try MathPreviewRuntime.renderJavaScript(), in: web)
        #expect(try await mathEvaluate("document.querySelectorAll('.note-math a,.note-math img,script').length", in: web) as? Int == 0)
        #expect(try await mathEvaluate("typeof window.evil", in: web) as? String == "undefined")
    }

    @Test func incompleteDollarInputDoesNotRepeatedlyScanTheWholeDocument() {
        let source = String(repeating: "$a ", count: 10_000)
        let clock = ContinuousClock()
        let start = clock.now
        let html = MarkdownPipeline.renderForPreview(source)
        #expect(!html.contains("note-math"))
        #expect(start.duration(to: clock.now) < .seconds(3))
    }

    @MainActor @Test func previewCoordinatorRendersMathAndRestoresScrollAfterLayout() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 350), configuration: configuration)
        let coordinator = HTMLPreview.Coordinator()
        web.navigationDelegate = coordinator
        let source = String(repeating: "$$\\frac{1}{2}$$\n\n", count: 70)
        coordinator.lastPage = MarkdownPipeline.previewPage(MarkdownPipeline.renderForPreview(source))
        coordinator.pageRevision = 1
        coordinator.scrollY = 1800
        coordinator.navigation = web.loadHTMLString(coordinator.lastPage, baseURL: URL(string: "about:blank"))
        for _ in 0..<200 {
            if !web.isLoading,
               try await mathEvaluate("document.querySelectorAll('.katex').length === 70 && window.scrollY === 1800", in: web) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Preview host did not render math and restore its scroll position")
    }
}

@MainActor private final class MathPageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(_ html: String, in web: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            web.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}

@MainActor private func mathEvaluate(_ script: String, in web: WKWebView) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
        web.evaluateJavaScript(script) { value, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: value) }
        }
    }
}
