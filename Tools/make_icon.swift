// Membuat ikon app (gelembung chat putih di atas kotak hijau) → PNG 1024px.
import Cocoa

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Kotak dasar ala macOS (inset 100px, radius ~22%)
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let base = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.86, blue: 0.48, alpha: 1),
           ending: NSColor(srgbRed: 0.09, green: 0.66, blue: 0.33, alpha: 1))!.draw(in: base, angle: -90)

// Gelembung chat
let bubble = NSBezierPath(ovalIn: NSRect(x: 252, y: 290, width: 520, height: 470))
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 300, y: 420))
tail.line(to: NSPoint(x: 250, y: 255))
tail.line(to: NSPoint(x: 420, y: 320))
tail.close()
NSColor.white.setFill()
bubble.fill(); tail.fill()

// Tiga titik
NSColor(srgbRed: 0.09, green: 0.66, blue: 0.33, alpha: 1).setFill()
for i in 0..<3 {
    NSBezierPath(ovalIn: NSRect(x: 362 + CGFloat(i) * 110, y: 492, width: 70, height: 70)).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
