#!/usr/bin/env swift
// Preview artwork only: does not modify the app's bundled icon.
import AppKit

let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("tools/prototypes/note-nas-icon.png")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func round(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func fill(_ shape: NSBezierPath, _ ink: NSColor) { ink.setFill(); shape.fill() }
func line(_ x: CGFloat, _ y: CGFloat, _ end: CGFloat, _ ink: NSColor, _ width: CGFloat) {
    let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: y)); p.line(to: NSPoint(x: end, y: y))
    p.lineWidth = width; p.lineCapStyle = .round; ink.setStroke(); p.stroke()
}
func glowShadow(_ blur: CGFloat, _ dy: CGFloat, _ opacity: CGFloat) {
    let s = NSShadow(); s.shadowColor = .black.withAlphaComponent(opacity)
    s.shadowBlurRadius = blur; s.shadowOffset = NSSize(width: 0, height: dy); s.set()
}

let size = 1024
let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: size * 4, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)!
let cg = NSGraphicsContext.current!.cgContext
cg.setAllowsAntialiasing(true)

// Rounded macOS icon background with a gentle blue gradient.
let background = round(66, 66, 892, 892, 204)
NSGraphicsContext.saveGraphicsState()
glowShadow(28, -15, 0.25)
fill(background, color(0x143A70))
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0x367DD6), ending: color(0x153669))!
    .draw(in: background, angle: -65)
color(0xFFFFFF, 0.15).setStroke(); background.lineWidth = 3; background.stroke()

// NAS is the background object; the notebook will overlap it in front.
let server = round(478, 270, 375, 395, 56)
NSGraphicsContext.saveGraphicsState(); glowShadow(30, -16, 0.3)
fill(server, color(0x102A4D)); NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0x2B527F), ending: color(0x142C4D))!
    .draw(in: server, angle: -90)
color(0xFFFFFF, 0.13).setStroke(); server.lineWidth = 3; server.stroke()

for y in [477.0, 351.0] {
    let tray = round(511, y, 304, 96, 22)
    fill(tray, color(0x0D2340))
    fill(round(533, y + 31, 181, 11, 5), color(0x6688AD))
    fill(NSBezierPath(ovalIn: NSRect(x: 772, y: y + 34, width: 18, height: 18)), color(0x67E4C4))
}
fill(round(639, 304, 60, 9, 5), color(0x6B8EAE, 0.72))

// Foreground hardcover notebook, with a real cloth spine and exposed rings.
let book = round(206, 215, 424, 590, 54)
NSGraphicsContext.saveGraphicsState(); glowShadow(30, -15, 0.30)
fill(book, color(0xEAF8FF)); NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0xF9FCFF), ending: color(0xC9E6F9))!
    .draw(in: book, angle: -75)
color(0xFFFFFF, 0.78).setStroke(); book.lineWidth = 4; book.stroke()

fill(round(206, 215, 80, 590, 34), color(0x234C7C))
fill(round(271, 215, 22, 590, 9), color(0x4883B4))
for y in [331.0, 445.0, 559.0, 673.0] {
    let ring = NSBezierPath(roundedRect: NSRect(x: 187, y: y, width: 91, height: 27), xRadius: 13, yRadius: 13)
    ring.lineWidth = 12
    color(0xE4F3FF).setStroke()
    ring.stroke()
    line(192, y + 13, 226, color(0x6A94C1), 4)
}

// A large, uncomplicated Markdown monogram on the front cover.
let label = NSAttributedString(string: "MD", attributes: [
    .font: NSFont.systemFont(ofSize: 154, weight: .heavy),
    .foregroundColor: color(0x285F8C),
    .kern: -7.0
])
let labelSize = label.size()
label.draw(at: NSPoint(x: 306 + (314 - labelSize.width) / 2, y: 466))
fill(round(352, 440, 173, 12, 6), color(0x87B5D6))
fill(round(367, 409, 140, 10, 5), color(0xB1D1E8))

let bytes = bmp.representation(using: .png, properties: [:])!
NSGraphicsContext.restoreGraphicsState()
try bytes.write(to: output, options: .atomic)
print(output.path)
