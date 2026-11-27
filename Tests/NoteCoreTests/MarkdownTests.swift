import Foundation
import Testing
import SwiftSoup
@testable import NoteCore

@Suite struct MarkdownTests {
    @Test func testDailyFrontMatterBecomesCollapsedPreviewInformationWithoutChangingSource() throws {
        let markdown = """
        ---
        type: daily
        date: 2026-05-27
        session_count: 34
        by_tool: {'claude-code': 4, 'codex': 30}
        by_project: {'lotto-web': 29, 'mindd-devops-web': 1}
        ---

        # 📅 2026-05-27 (수)

        > 34개 세션 · claude-code(4) / codex(30)

        ## 🤖 AI 회고

        **청구서 정산 흐름을 추적했다.**

        ### 주요 작업

        - **청구서 정산 및 SCAN 누락 원인 조사**
          - 수동 생성과 rebill만으로는 처리되지 않음을 확인했다.

        <!-- wiki:keep -->
        <!-- end:wiki:keep -->
        """
        let before = Data(markdown.utf8)
        let source = SourceEnvelope(documentID: UUID(), markdown: markdown, blocks: [], html: "<p>보존</p>")
        let restored = try SourceEnvelope.decode(source.encoded())
        #expect(Data(restored.markdown.utf8) == before)

        let html = MarkdownPipeline.renderForPreview(markdown)
        let dom = try SwiftSoup.parse(MarkdownPipeline.previewPage(html))
        #expect(try dom.select("details.note-frontmatter").count == 1)
        #expect(try dom.select("details.note-frontmatter[open]").isEmpty())
        #expect(try dom.select("details > summary").text() == coreText("Document Information"))
        let metadata = try dom.select("details pre code").text(trimAndNormaliseWhitespace: false)
        #expect(metadata.contains("session_count: 34"))
        #expect(metadata.contains("'lotto-web': 29"))
        #expect(try dom.select("h1").text() == "📅 2026-05-27 (수)")
        #expect(try dom.select("blockquote").text().contains("34개 세션"))
        #expect(try dom.select("h2").text() == "🤖 AI 회고")
        #expect(try dom.select("h2 + p strong").text() == "청구서 정산 흐름을 추적했다.")
        #expect(try dom.select("li strong").text() == "청구서 정산 및 SCAN 누락 원인 조사")
        #expect(try dom.select("li li").text().contains("rebill"))
        #expect(try !dom.outerHtml().contains("wiki:keep"))
        #expect(Data(markdown.utf8) == before)
    }

    @Test func testFrontMatterIsPreviewOnlyAndEscaped() throws {
        let markdown = "---\r\nname: '<img src=x onerror=alert(1)>'\r\n---\r\n\r\n# 안전"
        let html = MarkdownPipeline.renderForPreview(markdown)
        let dom = try SwiftSoup.parse(MarkdownPipeline.previewPage(html))
        #expect(try dom.select("details code").text().contains("<img src=x onerror=alert(1)>"))
        #expect(try dom.select("img").isEmpty())
        #expect(try dom.select("h1").text() == "안전")
        #expect(MarkdownPipeline.render(markdown) != html)
        #expect(!MarkdownPipeline.render(markdown).contains("note-frontmatter"))
        let withBOM = "\u{FEFF}---\nname: BOM\n...\n\n# 본문"
        #expect(MarkdownPipeline.renderForPreview(withBOM).contains("note-frontmatter"))
        #expect(MarkdownPipeline.renderForPreview(withBOM).contains("<h1>본문</h1>"))
    }

    @Test func testIncompleteOrNonLeadingDelimitersStayOrdinaryMarkdown() {
        for markdown in [
            "---\ntype: daily\n# 종료 없는 문서",
            "# 본문\n\n---\ntype: daily\n---",
            "```yaml\n---\ntype: daily\n---\n```",
            "---\n내용이 닫히지 않았다",
        ] {
            #expect(!MarkdownPipeline.renderForPreview(markdown).contains("note-frontmatter"))
            #expect(MarkdownPipeline.renderForPreview(markdown) == MarkdownPipeline.render(markdown))
        }
    }

    @Test func testCommonMarkAndGFMRenderThroughAST() throws {
        let html = MarkdownPipeline.render("""
        # 제목 **강조**

        > 인용 *기울임*

        3. 항목
           - 중첩

        - [x] 완료
        - [ ] 대기

        | 이름 | 값 |
        | :--- | ---: |
        | 한글 | ~~취소~~ |

        ```swift
        let x = "<tag>&"
        ```

        [링크](https://example.com "제목") ![대체](attachment://image "이미지")
        """)
        let dom = try SwiftSoup.parseBodyFragment(html)
        #expect(try dom.select("h1 strong").text() == "강조")
        #expect(try dom.select("blockquote em").text() == "기울임")
        #expect(try dom.select("ol").attr("start") == "3")
        #expect(try dom.select("ol ul li").text() == "중첩")
        #expect(try dom.select("input[type=checkbox][checked]").count == 1)
        #expect(try dom.select("input[type=checkbox]").count == 2)
        #expect(try dom.select("table tbody td del").text() == "취소")
        #expect(try dom.select("pre code.language-swift").text() == "let x = \"<tag>&\"")
        #expect(try dom.select("img").attr("alt") == "대체")
        #expect(try dom.select("a").attr("title") == "제목")
    }

    @Test func testRenderingEscapesTextCodeAndAttributes() throws {
        let html = MarkdownPipeline.render("# **& < >**\n\n`<img src=x onerror=evil()>`\n\n```html\n<script>alert(1)</script>\n```\n\n[x](<https://example.com/\"x>)")
        let dom = try SwiftSoup.parseBodyFragment(html)
        #expect(try dom.select("script,img").isEmpty())
        #expect(try dom.select("h1 strong").text() == "& < >")
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test func testImportSimpleHTMLAsEditableMarkdown() throws {
        let imported = MarkdownPipeline.importHTML("<h2>제목</h2><p>안녕 <strong>강조</strong> &amp; <em>기울임</em><br>다음</p><ul><li>하나</li><li>둘</li></ul>")
        #expect(imported.safeToEdit)
        #expect(imported.blocks.isEmpty)
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.render(imported.markdown))
        #expect(try dom.select("h2").text() == "제목")
        #expect(try dom.select("strong").text() == "강조")
        #expect(try dom.select("ul li").count == 2)
        #expect(try dom.select("br").count == 1)
    }

    @Test func testMergedTableIsPreservedByteForByteBetweenEditableParagraphs() throws {
        let table = "<TABLE data-id='원본' ><tr><td colspan='2'>병합 &amp; 🐱</td></tr>\n</TABLE>"
        let imported = MarkdownPipeline.importHTML("<p>앞</p>" + table + "<p>뒤</p>")
        #expect(imported.safeToEdit)
        #expect(imported.blocks.count == 1)
        #expect(imported.blocks.first?.html == table)
        #expect(imported.markdown.contains(":::synology-block "))
        let rendered = MarkdownPipeline.render(imported.markdown.replacingOccurrences(of: "앞", with: "수정"), blocks: imported.blocks)
        #expect(rendered.contains(table))
        #expect(rendered.contains("수정"))
        #expect(!(rendered.contains(":::synology-block")))
        let before = try #require(rendered.range(of: "수정"))
        let preserved = try #require(rendered.range(of: table))
        let after = try #require(rendered.range(of: "뒤"))
        #expect(before.lowerBound < preserved.lowerBound)
        #expect(preserved.lowerBound < after.lowerBound)
        #expect(MarkdownPipeline.importHTML("<p>앞</p>" + table + "<p>뒤</p>").blocks == imported.blocks)
    }

    @Test func testStylesWidgetsAndNestedTablesKeepExactOpaquePayload() {
        for raw in ["<p style='color: red'>색 <u>밑줄</u></p>", "<div class='synology-audio' data-file='42'><audio src='attachment://42'></audio></div>", "<table><tr><td><table><tr><td>중첩</td></tr></table></td></tr></table>"] {
            let imported = MarkdownPipeline.importHTML("<p>문단</p>" + raw)
            #expect(imported.safeToEdit)
            #expect(imported.blocks.first?.html == raw)
            #expect(MarkdownPipeline.render(imported.markdown, blocks: imported.blocks).contains(raw))
        }
    }

    @Test func testMalformedHTMLFailsClosedWithoutLosingOriginal() {
        let raw = "<p>앞<div style='color:red'>닫히지 않은 위젯"
        let imported = MarkdownPipeline.importHTML(raw)
        #expect(!(imported.safeToEdit))
        #expect(imported.blocks.map(\.html).joined() == raw)
    }

    @Test func testBlockValidationRejectsUnknownDuplicateAndDeletedPayloads() {
        let block = PreservedBlock(id: "known", html: "<div>원본</div>", label: "원본")
        #expect(MarkdownPipeline.validateBlocks(MarkdownPipeline.token(for: block), blocks: [block]))
        #expect(!(MarkdownPipeline.validateBlocks(":::synology-block missing :::", blocks: [block])))
        #expect(!(MarkdownPipeline.validateBlocks("삭제", blocks: [block])))
        #expect(!(MarkdownPipeline.validateBlocks(":::synology-block known :::\n\n:::synology-block known :::", blocks: [block])))
        #expect(!(MarkdownPipeline.validateBlocks(":::synology-block known :::", blocks: [block, block])))
        #expect(MarkdownPipeline.render(":::synology-block missing :::", blocks: [block]) == "")
        #expect(MarkdownPipeline.render("삭제", blocks: [block]) == "")
    }

    @Test func testTokenInFencedCodeIsLiteralAndNeverExpandsPayload() throws {
        let html = MarkdownPipeline.render("```text\n:::synology-block example :::\n```")
        #expect(try SwiftSoup.parseBodyFragment(html).select("code").text() == ":::synology-block example :::")
    }

    @Test func testSanitizerRemovesExecutionAndUnsafeURLsWithoutMutatingPayload() throws {
        let raw = "<script>alert(1)</script><p onclick='evil()' style='background:url(https://evil.test/x)'>본문</p><a href='java&#x73;cript:evil()'>링크</a><img src='data:image/svg+xml,evil' onerror='evil()'><iframe src='https://evil.test'></iframe><meta http-equiv='refresh' content='0;url=https://evil.test'><svg onload='evil()'></svg>"
        let safe = MarkdownPipeline.sanitize(raw)
        let dom = try SwiftSoup.parseBodyFragment(safe)
        #expect(try dom.select("script,iframe,meta,svg").isEmpty())
        #expect(try dom.select("[onclick],[onerror],[style]").isEmpty())
        #expect(try dom.select("a").attr("href") == "")
        #expect(try dom.select("img").attr("src") == "")
        #expect(safe.contains("본문"))
        let imported = MarkdownPipeline.importHTML(raw)
        #expect(imported.blocks.map(\.html).joined().contains("<script>alert(1)</script>"))
    }

    @Test func testPreviewWrapsSanitizedBodyInNetworkBlockedCSP() throws {
        let page = MarkdownPipeline.previewPage("<p>본문</p><script>evil()</script><img src='https://evil.test/a'>")
        let dom = try SwiftSoup.parse(page)
        let csp = try dom.select("meta[http-equiv=Content-Security-Policy]").attr("content")
        #expect(csp.contains("default-src 'none'"))
        #expect(csp.contains("script-src 'none'"))
        #expect(csp.contains("connect-src 'none'"))
        #expect(csp.contains("img-src data: attachment:"))
        #expect(!(csp.contains("https:")))
        #expect(try dom.select("script").isEmpty())
        #expect(try dom.select("body p").text() == "본문")
    }

    @Test func testSourceEnvelopeRoundTripsExactMarkdownAndBlocks() throws {
        let markdown = "---\r\ntitle: 사용자 메타\r\n---\r\n\r\n# 한글 🐱  \r\n\n:::synology-block table-1 :::\n"
        let blocks = [PreservedBlock(id: "table-1", html: "<table><tr><td colspan='2'>원본</td></tr></table>", label: "원본 표")]
        let envelope = SourceEnvelope(documentID: UUID(), markdown: markdown, blocks: blocks, html: "<p>본문</p>")
        let data = envelope.encoded()
        #expect(String(decoding: data, as: UTF8.self).hasSuffix(markdown))
        let decoded = try SourceEnvelope.decode(data)
        #expect(decoded.documentID == envelope.documentID)
        #expect(Array(decoded.markdown.utf8) == Array(markdown.utf8))
        #expect(decoded.blocks == blocks)
        #expect(decoded.matches(html: "<p>본문</p>"))
        #expect(!(decoded.matches(html: "<p>외부 수정</p>")))
    }

    @Test func testFingerprintFailsClosedForUnverifiedNormalization() {
        let html = "<p style='white-space:pre'>A  B</p><img src='https://nas.test/image?token=old'>"
        let source = SourceEnvelope(documentID: UUID(), markdown: "A  B", blocks: [], html: html)
        #expect(source.matches(html: html))
        #expect(!(source.matches(html: html.replacingOccurrences(of: "A  B", with: "A B"))))
        #expect(!(source.matches(html: html.replacingOccurrences(of: "token=old", with: "token=new"))))
        #expect(!(source.matches(html: html.replacingOccurrences(of: "white-space:pre", with: "white-space:normal"))))
        #expect(SourceEnvelope.fingerprint("<p>a</p>") != SourceEnvelope.fingerprint("<p>b</p>"))
    }

    @Test func testEnvelopeDecodeRejectsUnknownFormatTruncationAndEditedSource() throws {
        let envelope = SourceEnvelope(documentID: UUID(), markdown: "원문", blocks: [], html: "<p>원문</p>")
        var edited = String(decoding: envelope.encoded(), as: UTF8.self)
        edited += "수정"
        #expect(throws: (any Error).self) { try SourceEnvelope.decode(Data(edited.utf8)) }
        #expect(throws: (any Error).self) { try SourceEnvelope.decode(Data("---\nuser: yes\n---\n".utf8)) }
        #expect(throws: (any Error).self) { try SourceEnvelope.decode(Data(envelope.encoded().prefix(20))) }
    }

    @Test func testSimpleTableTaskListsAndCodeImportWithoutDataLoss() throws {
        let imported = MarkdownPipeline.importHTML("<table><thead><tr><th>항목</th><th align='right'>값</th></tr></thead><tbody><tr><td>한글 | 내용</td><td align='right'><strong>굵게</strong></td></tr></tbody></table><ul><li><input type='checkbox' checked>완료</li><li><p><input type='checkbox'>대기</p></li></ul><pre><code class='language-swift'>let x = &quot;&lt;a&gt;&quot;\n</code></pre>")
        #expect(imported.safeToEdit)
        #expect(imported.blocks.isEmpty)
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.render(imported.markdown))
        #expect(try dom.select("td").first()?.text() == "한글 | 내용")
        #expect(try dom.select("td strong").text() == "굵게")
        #expect(try dom.select("input[type=checkbox]").count == 2)
        #expect(try dom.select("input[checked]").count == 1)
        #expect(try dom.select("pre code").text(trimAndNormaliseWhitespace: false) == "let x = \"<a>\"\n")
    }

    @Test func testStandaloneCheckboxCannotDisappearDuringImport() {
        for raw in ["<input type='checkbox' checked>", "<p>할 일 <input type='checkbox'>확인</p>"] {
            let imported = MarkdownPipeline.importHTML(raw)
            #expect(imported.blocks.map(\.html).joined() == raw)
            #expect(MarkdownPipeline.render(imported.markdown, blocks: imported.blocks).contains(raw))
        }
    }

    @Test func testLiteralMarkdownAndTokensSurviveHTMLTextImport() throws {
        let text = "1. **원문** [링크](a) &amp; &lt;img&gt; :::synology-block example :::"
        let imported = MarkdownPipeline.importHTML("<p>" + text + "</p>")
        #expect(imported.blocks.isEmpty)
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.render(imported.markdown))
        #expect(try dom.select("p").text() == "1. **원문** [링크](a) & <img> :::synology-block example :::")
        #expect(try dom.select("strong,a,img,ol").isEmpty())
    }

    @Test func testDuplicateOpaqueBlocksHaveDistinctStableIDs() {
        let raw = "<div data-widget='x'>원본</div>"
        let imported = MarkdownPipeline.importHTML(raw + raw)
        #expect(imported.blocks.count == 2)
        #expect(Set(imported.blocks.map(\.id)).count == 2)
        #expect(MarkdownPipeline.validateBlocks(imported.markdown, blocks: imported.blocks))
        let rendered = MarkdownPipeline.render(imported.markdown, blocks: imported.blocks)
        #expect(rendered.components(separatedBy: raw).count == 3)
        #expect(MarkdownPipeline.importHTML(raw + raw).blocks == imported.blocks)
    }

    @Test func testPreviewPreservesSafeLinksForHostNavigationDelegate() throws {
        let page = MarkdownPipeline.previewPage("<a href='https://example.test'>원격</a><a href='http://example.test'>HTTP</a><a href='mailto:note@example.test'>메일</a><a href='#section'>내부</a><a href='javascript:evil()'>위험</a><img src='attachment://42'><input type='text' autofocus><input type='checkbox' checked onclick='evil()'>")
        let dom = try SwiftSoup.parse(page)
        #expect(try dom.select("a[href]").count == 4)
        #expect(try dom.select("a[href^=https:]").attr("href") == "https://example.test")
        #expect(try dom.select("a[href^=http:]").attr("href") == "http://example.test")
        #expect(try dom.select("a[href^=mailto:]").attr("href") == "mailto:note@example.test")
        #expect(try dom.select("a[href=\"#section\"]").count == 1)
        #expect(try dom.select("img").attr("src") == "attachment://42")
        #expect(try dom.select("input").count == 1)
        #expect(try dom.select("input[disabled][checked]").count == 1)
    }

    @Test func testSanitizerRejectsObfuscatedAndExecutableURLSchemes() throws {
        for url in ["JaVaScRiPt:evil()", "java&#10;script:evil()", "vbscript:evil()", "file:///tmp/private", "data:text/html,evil", "blob:https://evil.test/id"] {
            let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.sanitize("<a href='" + url + "'>링크</a><img src='" + url + "'>"))
            #expect(try dom.select("[href],[src]").isEmpty())
        }
    }

    @Test func testEnvelopeRejectsFutureNormalizationAndCorruptBlockPayload() throws {
        let block = PreservedBlock(id: "original", html: "<div data-widget='x'>원본</div>", label: "원본")
        let source = SourceEnvelope(documentID: UUID(), markdown: MarkdownPipeline.token(for: block), blocks: [block], html: block.html)
        let original = String(decoding: source.encoded(), as: UTF8.self)
        let header = try #require(original.components(separatedBy: "\n").first)
        let base64 = String(header.dropFirst("<!-- synology-note-source:v1 ".count).dropLast(" -->".count))
        let bytes = try #require(Data(base64Encoded: base64))
        let metadata = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        func mutated(_ edits: ([String: Any]) -> [String: Any]) throws -> Data {
            let data = try JSONSerialization.data(withJSONObject: edits(metadata))
            return Data(("<!-- synology-note-source:v1 " + data.base64EncodedString() + " -->\n" + source.markdown).utf8)
        }
        let future = try mutated { var m = $0; m["fingerprintVersion"] = 2; return m }
        #expect(throws: SourceEnvelopeError.unsupportedVersion) { try SourceEnvelope.decode(future) }
        let corrupt = try mutated { var m = $0; m["blocks"] = [["id": "original", "html": "내용 유실", "label": "원본"]]; return m }
        #expect(throws: (any Error).self) { try SourceEnvelope.decode(corrupt) }
    }

    @Test func testLinksAndImagesImportIntoMarkdownSyntax() throws {
        let imported = MarkdownPipeline.importHTML("<p><a href='https://example.test/a' title='제목'>링크</a> <img src='attachment://42' alt='대체' title='사진'></p>")
        #expect(imported.blocks.isEmpty)
        #expect(imported.markdown.contains("[링크](https://example.test/a \"제목\")"))
        #expect(imported.markdown.contains("![대체](attachment://42 \"사진\")"))
        let dom = try SwiftSoup.parseBodyFragment(MarkdownPipeline.render(imported.markdown))
        #expect(try dom.select("a").attr("href") == "https://example.test/a")
        #expect(try dom.select("a").attr("title") == "제목")
        #expect(try dom.select("img").attr("src") == "attachment://42")
        #expect(try dom.select("img").attr("alt") == "대체")
    }

    @Test func testInlineEmphasisNeverChangesMeaningDuringImport() throws {
        for raw in ["<p>a<strong>b</strong>c</p>", "<p><strong>a</strong><em>b</em></p>", "<p>한글<em>기울임</em>글</p>", "<p><strong><em>모두</em></strong></p>"] {
            let imported = MarkdownPipeline.importHTML(raw)
            let original = try SwiftSoup.parseBodyFragment(raw)
            let rendered = try SwiftSoup.parseBodyFragment(MarkdownPipeline.render(imported.markdown, blocks: imported.blocks))
            #expect(try original.select("strong").text() == rendered.select("strong").text())
            #expect(try original.select("em").text() == rendered.select("em").text())
            #expect(try original.body()?.text() == rendered.body()?.text())
        }
    }

    @Test func testBlockTokensMustRemainStandaloneAndOutsideLiteralCode() {
        let block = PreservedBlock(id: "x", html: "<div data-x='1'>원본</div>", label: "원본")
        for malformed in ["앞\n:::synology-block x :::", ":::synology-block x", ":::synology-block x ::: 뒤", "# :::synology-block x :::"] {
            #expect(!MarkdownPipeline.validateBlocks(malformed, blocks: [block]))
            #expect(MarkdownPipeline.render(malformed, blocks: [block]).isEmpty)
        }
        #expect(MarkdownPipeline.validateBlocks("`:::synology-block x :::`", blocks: []))
        #expect(MarkdownPipeline.validateBlocks("\\:::synology-block x :::", blocks: []))
    }

    @Test func testTableCaptionColumnsAndFooterCannotBeDiscarded() {
        for raw in ["<table><caption>제목</caption><tr><th>열</th></tr><tr><td>값</td></tr></table>", "<table><colgroup><col></colgroup><tr><th>열</th></tr></table>", "<table><thead><tr><th>열</th></tr></thead><tfoot><tr><td>합계</td></tr></tfoot></table>"] {
            let imported = MarkdownPipeline.importHTML(raw)
            #expect(imported.blocks.map(\.html).joined() == raw)
            #expect(MarkdownPipeline.render(imported.markdown, blocks: imported.blocks).contains(raw))
        }
    }
}
