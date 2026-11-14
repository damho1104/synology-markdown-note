import AppKit
import Foundation
import Network
import Testing
@testable import NoteCore
@testable import SynologyNote

@Suite(.serialized) @MainActor struct MathImageRendererTests {
    @Test func emptyInputDoesNotStartWebKit() async throws {
        let images = try await MathImageRenderer(timeout: .zero).render([])
        #expect(images.isEmpty)
    }

    @Test func rendersRealPNGWithDifferentInlineAndDisplayBounds() async throws {
        let inline = MathFormula(tex: #"\sum_{i=1}^{n}\frac{1}{i^2}"#, display: false)
        let display = MathFormula(tex: inline.tex, display: true)
        let images = try await MathImageRenderer().render([inline, display])
        #expect(images.map(\.key) == [inline.key, display.key])
        let first = try #require(images.first)
        let last = try #require(images.last)
        try assertLegiblePNG(first)
        try assertLegiblePNG(last)
        #expect(last.height > first.height)
        #expect(first.width < 400)
        #expect(first.height < 150)
    }

    @Test func duplicatesProduceOneImageInFirstOccurrenceOrder() async throws {
        let a = MathFormula(tex: "a+b", display: false)
        let b = MathFormula(tex: "c=d", display: true)
        let images = try await MathImageRenderer().render([a, a, b, a, b])
        #expect(images.map(\.key) == [a.key, b.key])
        for image in images { try assertLegiblePNG(image) }
    }

    @Test func invalidTeXRetainsVisibleSourceAsErrorImage() async throws {
        let formula = MathFormula(tex: #"\frac{"#, display: false)
        let longer = MathFormula(tex: #"\frac{UNIQUE ORIGINAL SOURCE 1234567890"#, display: false)
        let images = try await MathImageRenderer().render([formula, longer])
        let image = try #require(images.first)
        try assertLegiblePNG(image)
        #expect(image.width > 40)
        #expect(try #require(images.last).width > image.width * 2)
        let bitmap = try #require(NSBitmapImageRep(data: image.data))
        var redPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   c.redComponent > c.greenComponent * 1.5, c.redComponent > 0.2 {
                    redPixels += 1
                }
            }
        }
        #expect(redPixels > 5)
    }

    @Test func darkAppearanceStillProducesWhiteBackgroundAndDarkGlyphs() async throws {
        let previous = NSApp?.appearance
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = previous }
        let images = try await MathImageRenderer().render([MathFormula(tex: "E=mc^2", display: false)])
        try assertLegiblePNG(try #require(images.first))
    }

    @Test func untrustedCommandsAndHTMLCannotLoadRemoteResourcesOrRunScripts() async throws {
        // Observe actual TCP attempts rather than assuming a successful image
        // means no network request was made by WebKit.
        let listener = try NWListener(using: .tcp, on: .any)
        let connections = MathConnectionCount()
        listener.newConnectionHandler = { connection in
            connections.increment()
            connection.cancel()
        }
        listener.start(queue: DispatchQueue(label: "MathImageRendererTests.network"))
        defer { listener.cancel() }
        for _ in 0..<100 {
            if listener.port != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try #require(listener.port?.rawValue)
        let url = "http://127.0.0.1:\(port)/never.png"
        let formulas = [
            MathFormula(tex: "\\includegraphics{\(url)}", display: false),
            MathFormula(tex: #"\href{javascript:document.body.remove()}{click}"#, display: false),
            MathFormula(tex: "</span><script>document.body.remove()</script><img src='\(url)'>", display: false)
        ]
        let images = try await MathImageRenderer().render(formulas)
        #expect(images.count == 3)
        for image in images { try assertLegiblePNG(image) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(connections.value == 0)
    }

    @Test func oversizedFormulaFitsConfiguredDimensions() async throws {
        let formula = MathFormula(tex: String(repeating: "x+", count: 150) + "x", display: true)
        let tall = MathFormula(tex: #"\begin{matrix}"# + String(repeating: #"x \\"#, count: 80) + #"x\end{matrix}"#, display: true)
        let images = try await MathImageRenderer(maximumWidth: 256, maximumHeight: 128).render([formula, tall])
        #expect(try #require(images.first).width == 256)
        #expect(try #require(images.last).height == 128)
        for image in images {
            #expect(image.width <= 256)
            #expect(image.height <= 128)
            let bitmap = try #require(NSBitmapImageRep(data: image.data))
            #expect(bitmap.pixelsWide <= 256)
            #expect(bitmap.pixelsHigh <= 128)
            // These deliberately extreme inputs shrink glyphs below a pixel.
            // Antialiasing must still retain ink; ordinary-size formulas above
            // require the stronger dark-glyph contrast threshold.
            try assertFormulaPNG(image, inkThreshold: 0.98)
        }
    }

    @Test func concurrentCallsKeepTheirOwnFormulaGeometry() async throws {
        let renderer: any MathImageRendering = MathImageRenderer()
        async let short = renderer.render([MathFormula(tex: "x", display: false)])
        async let wide = renderer.render([MathFormula(tex: String(repeating: "x+", count: 12), display: true)])
        let (a, b) = try await (short, wide)
        #expect(try #require(a.first).width < 50)
        #expect(try #require(b.first).width > 200)
        try assertLegiblePNG(try #require(a.first))
        try assertLegiblePNG(try #require(b.first))
    }

    @Test func cancelledRenderingThrowsAndRendererCanBeReused() async throws {
        let renderer = MathImageRenderer()
        let formula = MathFormula(tex: "x", display: false)
        let task = Task { try await renderer.render(Array(repeating: formula, count: 50)) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled render returned an image")
        } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        let clock = ContinuousClock()
        let start = clock.now
        let active = Task {
            try await renderer.render((0..<100).map { MathFormula(tex: "x_\($0)", display: false) })
        }
        try await Task.sleep(for: .milliseconds(50))
        active.cancel()
        do {
            _ = try await active.value
            Issue.record("In-flight cancellation returned images")
        } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(start.duration(to: clock.now) < .seconds(2))
        let images = try await renderer.render([formula])
        try assertLegiblePNG(try #require(images.first))
    }

    @Test func elapsedDeadlineThrowsInsteadOfHanging() async throws {
        for timeout in [Duration.zero, .milliseconds(1)] {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                _ = try await MathImageRenderer(timeout: timeout).render([MathFormula(tex: "x", display: false)])
                Issue.record("Expired deadline returned an image")
            } catch MathImageRenderer.RenderingError.timedOut {}
            catch { Issue.record("Unexpected timeout error: \(error)") }
            #expect(start.duration(to: clock.now) < .seconds(2))
        }
    }

    private func assertLegiblePNG(_ image: RenderedMathImage) throws {
        try assertFormulaPNG(image, inkThreshold: 0.8)
    }

    private func assertFormulaPNG(_ image: RenderedMathImage, inkThreshold: Double) throws {
        #expect(Array(image.data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let bitmap = try #require(NSBitmapImageRep(data: image.data))
        #expect(image.width > 0 && image.height > 0)
        #expect(bitmap.pixelsWide >= Int(image.width))
        #expect(bitmap.pixelsHigh >= Int(image.height))
        let corner = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(corner.redComponent > 0.95 && corner.greenComponent > 0.95 && corner.blueComponent > 0.95)
        #expect(corner.alphaComponent > 0.95)
        var visiblePixels = 0
        var darkest = 1.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    let channel = min(c.redComponent, c.greenComponent, c.blueComponent)
                    darkest = min(darkest, channel)
                    if channel < inkThreshold { visiblePixels += 1 }
                }
            }
        }
        #expect(visiblePixels > 5, "A valid but blank PNG loses the formula; darkest channel: \(darkest)")
    }
}

private final class MathConnectionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
