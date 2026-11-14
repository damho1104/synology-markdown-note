import SwiftUI
import WebKit
import UniformTypeIdentifiers
import NoteCore

struct PreviewView: View {
    var markdown: String?
    var originalHTML: String?
    var blocks: [PreservedBlock]
    var attachments: [NoteAttachment]
    var assetStore: AttachmentStore
    var onToggleTask: ((Int) -> Void)? = nil
    var onOpenNote: ((String) -> Void)? = nil
    @State private var page = ""
    @AppStorage("mermaidStyle") private var mermaidStyle: MermaidStyle = .sketch
    @AppStorage("mermaidTheme") private var mermaidTheme: MermaidTheme = .automatic
    private var input: PreviewInput { PreviewInput(markdown: markdown, html: originalHTML, blocks: blocks, attachments: attachments) }
    var body: some View {
        HTMLPreview(page: page, attachments: attachments, assetStore: assetStore, mermaidStyle: mermaidStyle, mermaidTheme: mermaidTheme, onToggleTask: onToggleTask, onOpenNote: onOpenNote)
            .task(id: input) {
                let value = input
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    let rendered = await Task.detached(priority: .userInitiated) {
                        let html = value.markdown.map { MarkdownPipeline.renderForPreview($0, blocks: value.blocks) } ?? value.html ?? ""
                        let resolved = AttachmentResolver.previewHTML(html, attachments: value.attachments)
                        let safe = MarkdownPipeline.sanitize(resolved)
                        let linked = value.markdown == nil ? safe : InternalNoteLinks.previewHTML(safe)
                        return MarkdownPipeline.previewPage(value.markdown == nil ? linked : MarkdownEditing.interactivePreview(linked))
                    }.value
                    guard !Task.isCancelled else { return }
                    page = rendered
                } catch {}
            }
    }
    private struct PreviewInput: Hashable, Sendable { var markdown: String?; var html: String?; var blocks: [PreservedBlock]; var attachments: [NoteAttachment] }
}

struct HTMLPreview: NSViewRepresentable {
    let page: String
    let attachments: [NoteAttachment]
    let assetStore: AttachmentStore
    let mermaidStyle: MermaidStyle
    let mermaidTheme: MermaidTheme
    var onToggleTask: ((Int) -> Void)?
    var onOpenNote: ((String) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let handler = AttachmentSchemeHandler(store: assetStore)
        handler.attachments = attachments
        configuration.setURLSchemeHandler(handler, forURLScheme: "attachment")
        let web = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.handler = handler
        web.navigationDelegate = context.coordinator
        web.setAccessibilityLabel("문서 미리보기")
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.handler?.attachments = attachments
        context.coordinator.onToggleTask = onToggleTask
        context.coordinator.onOpenNote = onOpenNote
        guard context.coordinator.lastPage != page
                || context.coordinator.mermaidStyle != mermaidStyle
                || context.coordinator.mermaidTheme != mermaidTheme else { return }
        context.coordinator.lastPage = page
        context.coordinator.mermaidStyle = mermaidStyle
        context.coordinator.mermaidTheme = mermaidTheme
        context.coordinator.pageRevision += 1
        let revision = context.coordinator.pageRevision
        // Snapshot only scroll position; user-authored JavaScript never runs.
        web.evaluateJavaScript("window.scrollY") { offset, _ in
            guard context.coordinator.pageRevision == revision else { return }
            context.coordinator.scrollY = offset as? Double ?? context.coordinator.scrollY
            context.coordinator.navigation = web.loadHTMLString(page, baseURL: URL(string: "about:blank"))
        }
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var lastPage = ""
        var mermaidStyle: MermaidStyle = .sketch
        var mermaidTheme: MermaidTheme = .automatic
        var scrollY = 0.0
        var pageRevision = 0
        var navigation: WKNavigation?
        fileprivate var handler: AttachmentSchemeHandler?
        var onToggleTask: ((Int) -> Void)?
        var onOpenNote: ((String) -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            let revision = pageRevision
            renderMathIfNeeded(in: webView) {
                guard self.pageRevision == revision else { return }
                self.renderMermaidIfNeeded(in: webView) {
                    guard self.pageRevision == revision else { return }
                    self.restoreScroll(in: webView, revision: revision)
                }
            }
        }
        private func renderMathIfNeeded(in webView: WKWebView, completion: @escaping () -> Void) {
            guard MathPreviewRuntime.hasMath(in: lastPage),
                  let script = try? MathPreviewRuntime.renderJavaScript() else { completion(); return }
            webView.evaluateJavaScript(script) { _, _ in completion() }
        }
        private func renderMermaidIfNeeded(in webView: WKWebView, completion: @escaping () -> Void) {
            guard MermaidPreviewRuntime.hasDiagram(in: lastPage),
                  let library = try? MermaidPreviewRuntime.libraryJavaScript() else { completion(); return }
            let revision = pageRevision
            webView.evaluateJavaScript(library) { _, error in
                guard self.pageRevision == revision else { return }
                guard error == nil else { completion(); return }
                webView.evaluateJavaScript(MermaidPreviewRuntime.bootstrapJavaScript(style: self.mermaidStyle, theme: self.mermaidTheme)) { _, _ in completion() }
            }
        }
        private func restoreScroll(in webView: WKWebView, revision: Int) {
            // Let both offline fonts and asynchronous Mermaid layout settle
            // before restoring a position near the end of a long document.
            webView.callAsyncJavaScript("""
            for (let attempt = 0; attempt < 100; attempt++) {
              const pendingDiagram = document.querySelector('.mermaid:not(:has(svg))');
              if (!pendingDiagram && document.fonts.status === 'loaded') break;
              await new Promise(resolve => setTimeout(resolve, 20));
            }
            return true;
            """, arguments: [:], in: nil, in: .page) { _ in
                guard self.pageRevision == revision else { return }
                webView.evaluateJavaScript("window.scrollTo(0, \(self.scrollY))", completionHandler: nil)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated else {
                let scheme = action.request.url?.scheme
                decisionHandler(scheme == "about" || scheme == "attachment" ? .allow : .cancel)
                return
            }
            if let url = action.request.url {
                if url.scheme == "note-task", let line = Int(url.host ?? "") { onToggleTask?(line) }
                else if url.scheme == "synology-note", url.host == "link",
                        let destination = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "destination" })?.value,
                        InternalNoteLinks.isInternal(destination) { onOpenNote?(destination) }
                else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            }
            decisionHandler(.cancel)
        }
    }
}

@MainActor private final class AttachmentSchemeHandler: NSObject, WKURLSchemeHandler {
    let store: AttachmentStore
    var attachments: [NoteAttachment] = []
    var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(store: AttachmentStore) { self.store = store }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let url = urlSchemeTask.request.url,
              let uuid = UUID(uuidString: url.host ?? ""),
              let attachment = attachments.first(where: { $0.id == uuid }) else {
            urlSchemeTask.didFailWithError(AttachmentError.missing); return
        }
        tasks[key] = Task {
            defer { tasks.removeValue(forKey: key) }
            do {
                let data = try await store.verifiedData(for: attachment)
                guard !Task.isCancelled else { return }
                let mime = UTType(filenameExtension: (attachment.name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel()
    }
}
