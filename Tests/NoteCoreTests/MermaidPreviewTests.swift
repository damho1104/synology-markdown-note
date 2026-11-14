import Foundation
import Testing
import WebKit
@testable import NoteCore
@testable import SynologyNote

@Suite struct MermaidPreviewTests {
    @Test func detectsMermaidCodeBlocksAndUsesStrictRendering() {
        let page = """
        <html><body>
        <pre><code class="language-swift">let x = 1</code></pre>
        <pre><code class="language-mermaid">graph TD\nA--&gt;B</code></pre>
        </body></html>
        """

        #expect(MermaidPreviewRuntime.hasDiagram(in: page))
        #expect(MermaidPreviewRuntime.bootstrapJavaScript().contains("securityLevel: 'strict'"))
        #expect(MermaidPreviewRuntime.bootstrapJavaScript().contains("code.language-mermaid"))
    }

    @Test func bundlesMermaidRuntimeForOfflinePreview() throws {
        let script = try MermaidPreviewRuntime.libraryJavaScript()
        #expect(script.count > 1_000_000)
        #expect(script.contains("mermaid"))
    }

    @MainActor
    @Test(arguments: MermaidStyle.allCases, [MermaidTheme.light, .dark, .forest])
    func rendersSelectedStyleAsSVGWithPageJavaScriptDisabled(style: MermaidStyle, theme: MermaidTheme) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let loader = PreviewLoadWaiter()
        webView.navigationDelegate = loader

        let html = MarkdownPipeline.render("""
        ```mermaid
        %% rough
        flowchart TD
          subgraph 클라우드/인프라
            A1[AWS EC2/RDS/Redis/Kafka/EMQX/DocumentDB]
            A2[NAVER Cloud]
            A3[Tailscale VPN]
          end
          subgraph 백엔드 시스템
            B1[Backoffice Web]
            B2[Mindd Web]
            B3[B2BAuth]
            B4[임상IoT Server]
            B5[MessageHub/알림톡]
          end
          subgraph 데이터/API관리
            C1[Swagger UI]
            C2[Nginx Proxy Manager]
            C3[Shlink URL Shortener]
            C4[n8n 워크플로우]
            C5[MongoDB/MySQL/MariaDB]
          end
          A1-- "VPC연동, VPN터널" -->A3
          A1-- "클러스터, 보안관제" -->C5
          A2-- "SMS/로그/API 인증 연계" -->C2
          C2-- "Reverse Proxy" -->B1
          C2-- "Reverse Proxy" -->B2
          C2-- "Reverse Proxy" -->B3
          B4-- "MQTT/TLS 브로커 및 데이터" -->C5
          C1-- "API Docs 연계" -->B1
          C1-- "API Docs 연계" -->B5
          B5-- "알림톡/SENS/EVENT" -->C3
          C4-- "CI/CD, 데이터 Export" -->C5
          B1---B2
          B1---B3
          B2---B4
          B3---B4
        ```
        """)
        let page = MarkdownPipeline.previewPage(html)
        try await loader.load(page, in: webView)

        _ = try await evaluateJavaScript(try MermaidPreviewRuntime.libraryJavaScript(), in: webView)
        _ = try await evaluateJavaScript(MermaidPreviewRuntime.bootstrapJavaScript(style: style, theme: theme), in: webView)

        for _ in 0..<100 {
            let value = try await evaluateJavaScript("document.querySelectorAll('.mermaid svg').length", in: webView)
            if (value as? NSNumber)?.intValue == 1 {
                let sketchNodes = try await evaluateJavaScript("document.querySelectorAll('.mermaid svg .rough-node').length", in: webView)
                #expect((sketchNodes as? NSNumber)?.intValue == (style == .sketch ? 13 : 0))
                let renderedTheme = try await evaluateJavaScript("mermaid.mermaidAPI.getConfig().theme", in: webView)
                #expect(renderedTheme as? String == theme.rawValue)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Mermaid diagram did not render to SVG")
    }
}

@MainActor
private final class PreviewLoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
private func evaluateJavaScript(_ script: String, in webView: WKWebView) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
        webView.evaluateJavaScript(script) { value, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: value) }
        }
    }
}
