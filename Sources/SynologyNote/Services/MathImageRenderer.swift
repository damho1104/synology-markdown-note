import AppKit
import Foundation
import NoteCore
import WebKit

/// Produces offline, light-background formula attachments for Note Station.
/// Each call owns its WebKit session so concurrent exports cannot replace one
/// another's DOM. Neither document HTML nor TeX is ever evaluated as JavaScript.
@MainActor final class MathImageRenderer: MathImageRendering {
    enum RenderingError: Error {
        case timedOut
        case invalidDimensions
        case invalidLayout
        case pngEncodingFailed
        case webContentProcessTerminated
    }

    private let maximumWidth: Double
    private let maximumHeight: Double
    private let timeout: Duration

    init(maximumWidth: Double = 2048, maximumHeight: Double = 2048, timeout: Duration = .seconds(15)) {
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.timeout = timeout
    }

    func render(_ formulas: [MathFormula]) async throws -> [RenderedMathImage] {
        guard !formulas.isEmpty else { return [] }
        try Task.checkCancellation()
        // Bound the backing surface as well as the exported dimensions. Invalid
        // configuration must not reach AppKit with NaN or an enormous allocation.
        guard maximumWidth.isFinite, maximumHeight.isFinite,
              maximumWidth >= 1, maximumHeight >= 1,
              maximumWidth <= 8192, maximumHeight <= 8192 else {
            throw RenderingError.invalidDimensions
        }
        guard timeout > .zero else { throw RenderingError.timedOut }
        var seen = Set<String>()
        let unique = formulas.filter { seen.insert($0.key).inserted }
        let script = try MathPreviewRuntime.renderJavaScript()
        let session = MathImageSession(width: maximumWidth, height: maximumHeight)
        defer { session.stop() }
        try await session.load(timeout: timeout)
        var images: [RenderedMathImage] = []
        for formula in unique {
            try Task.checkCancellation()
            let deadline = ContinuousClock.now.advanced(by: timeout)
            // JSON data is passed to the trusted host script, then assigned via
            // textContent. Closing tags, quotes and commands remain literal TeX.
            let json = try JSONSerialization.data(withJSONObject: [formula.tex, formula.display])
            let encoded = String(decoding: json, as: UTF8.self)
            _ = try await session.evaluate("""
            (() => {
              const input = \(encoded);
              const frame = document.getElementById('formula');
              frame.style.transform = '';
              frame.replaceChildren();
              const element = document.createElement('span');
              element.className = 'note-math ' + (input[1] ? 'note-math-display' : 'note-math-inline');
              element.textContent = input[0];
              frame.appendChild(element);
            })();
            \(script)
            """, deadline: deadline)
            let size = try await session.stableSize(deadline: deadline)
            let scale = min(1, maximumWidth / size.width, maximumHeight / size.height)
            let width = min(maximumWidth, ceil(size.width * scale))
            let height = min(maximumHeight, ceil(size.height * scale))
            _ = try await session.evaluate("""
            document.getElementById('formula').style.transform = 'scale(\(scale))';
            void document.getElementById('formula').getBoundingClientRect();
            """, deadline: deadline)
            // Layout is asynchronous, including after a transform. Observe the
            // scaled geometry across several event-loop turns before capturing.
            _ = try await session.stableSize(deadline: deadline)
            let data = try await session.snapshot(width: width, height: height, deadline: deadline)
            images.append(RenderedMathImage(key: formula.key, data: data, width: width, height: height))
        }
        return images
    }
}

@MainActor private final class MathImageSession: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private var loaded = false
    private var navigationError: Error?

    init(width: Double, height: Double) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        super.init()
        web.appearance = NSAppearance(named: .aqua)
        web.navigationDelegate = self
    }

    func stop() {
        web.stopLoading()
        web.navigationDelegate = nil
    }

    func load(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        web.loadHTMLString(Self.page, baseURL: URL(string: "about:blank"))
        while !loaded {
            try check(deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(deadline)
    }

    func evaluate(_ script: String, deadline: ContinuousClock.Instant) async throws -> Any? {
        try check(deadline)
        let pending = MathImagePending<Any?>()
        beginEvaluation(script, pending: pending)
        return try await wait(pending, deadline: deadline)
    }

    private func beginEvaluation(_ script: String, pending: MathImagePending<Any?>) {
        web.evaluateJavaScript(script) { [weak pending] value, error in
            pending?.result = error.map { .failure($0) } ?? .success(value)
        }
    }

    func stableSize(deadline: ContinuousClock.Instant) async throws -> CGSize {
        var previous = CGSize.zero
        var stable = 0
        while true {
            let value = try await evaluate("""
            (() => {
              const r = document.getElementById('formula').getBoundingClientRect();
              return {ready: document.fonts.status === 'loaded', width: r.width, height: r.height};
            })()
            """, deadline: deadline) as? [String: Any]
            guard let value,
                  let width = value["width"] as? Double,
                  let height = value["height"] as? Double,
                  width.isFinite, height.isFinite, width > 0, height > 0 else {
                throw MathImageRenderer.RenderingError.invalidLayout
            }
            let size = CGSize(width: width, height: height)
            if value["ready"] as? Bool == true && size == previous {
                stable += 1
                if stable >= 3 { return size }
            } else { stable = 0 }
            previous = size
            try check(deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func snapshot(width: Double, height: Double, deadline: ContinuousClock.Instant) async throws -> Data {
        try check(deadline)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        configuration.snapshotWidth = NSNumber(value: width)
        configuration.afterScreenUpdates = true
        let pending = MathImagePending<NSImage>()
        web.takeSnapshot(with: configuration) { [weak pending] image, error in
            if let error { pending?.result = .failure(error) }
            else if let image { pending?.result = .success(image) }
            else { pending?.result = .failure(MathImageRenderer.RenderingError.pngEncodingFailed) }
        }
        let image = try await wait(pending, deadline: deadline)
        guard let tiff = image.tiffRepresentation,
              let original = NSBitmapImageRep(data: tiff) else {
            throw MathImageRenderer.RenderingError.pngEncodingFailed
        }
        let bitmap: NSBitmapImageRep
        // WebKit captures at the screen's backing scale, often 2x. Keep that
        // extra detail when it fits, but bound the encoded pixels as well as the
        // HTML attachment dimensions on Retina displays.
        if Double(original.pixelsWide) > web.bounds.width || Double(original.pixelsHigh) > web.bounds.height {
            let scale = min(web.bounds.width / Double(original.pixelsWide), web.bounds.height / Double(original.pixelsHigh))
            let pixelsWide = max(1, Int(floor(Double(original.pixelsWide) * scale)))
            let pixelsHigh = max(1, Int(floor(Double(original.pixelsHigh) * scale)))
            guard let reduced = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: reduced) else {
                throw MathImageRenderer.RenderingError.pngEncodingFailed
            }
            let rect = NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            NSColor.white.setFill()
            rect.fill()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            bitmap = reduced
        } else { bitmap = original }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw MathImageRenderer.RenderingError.pngEncodingFailed
        }
        try check(deadline)
        return data
    }

    // Callback results are polled with a deadline instead of an unbounded
    // continuation: WebKit can stop replying when its process dies. Callbacks
    // hold the box weakly, so cancellation/timeout leaves no retained session.
    private func wait<Value>(_ pending: MathImagePending<Value>, deadline: ContinuousClock.Instant) async throws -> Value {
        while true {
            try check(deadline)
            if let result = pending.result { return try result.get() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        if let navigationError { throw navigationError }
        guard ContinuousClock.now < deadline else { throw MathImageRenderer.RenderingError.timedOut }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationError = MathImageRenderer.RenderingError.webContentProcessTerminated
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src data:; img-src 'none'; connect-src 'none'; script-src 'none'; base-uri 'none'; form-action 'none'">
    <meta name="color-scheme" content="light">
    <style>
      :root {color-scheme:light only}
      html,body {margin:0;padding:0;background:#fff!important;color:#111!important;overflow:hidden}
      body {font:16px -apple-system,BlinkMacSystemFont,sans-serif}
      #formula {display:inline-block;width:max-content;min-width:1px;min-height:1px;padding:6px;background:#fff;transform-origin:top left}
      #formula .note-math {max-width:none!important;overflow:visible!important}
      #formula .note-math-inline {display:inline-block}
      #formula .note-math-error {color:#b42318!important}
    </style></head><body><div id="formula"></div></body></html>
    """
}

@MainActor private final class MathImagePending<Value> {
    var result: Result<Value, Error>?
}
