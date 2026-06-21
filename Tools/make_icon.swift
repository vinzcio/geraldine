// Generates Resources/AppIcon.icns — an original mark: a violet→blue
// squircle with a white sparkle glyph. Run: swift Tools/make_icon.swift
import AppKit
import Foundation

func makeIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.235
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let blue = NSColor(srgbRed: 0.36, green: 0.66, blue: 0.98, alpha: 1)
    let violet = NSColor(srgbRed: 0.46, green: 0.40, blue: 0.95, alpha: 1)
    if let grad = NSGradient(starting: blue, ending: violet) { grad.draw(in: path, angle: -55) }

    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) {
        let conf = NSImage.SymbolConfiguration(pointSize: size * 0.48, weight: .bold)
        if let glyph = symbol.withSymbolConfiguration(conf) {
            let gs = glyph.size
            let white = NSImage(size: gs)
            white.lockFocus()
            glyph.draw(at: .zero, from: NSRect(origin: .zero, size: gs), operation: .sourceOver, fraction: 1)
            NSColor.white.set()
            NSRect(origin: .zero, size: gs).fill(using: .sourceAtop)
            white.unlockFocus()
            let drawRect = NSRect(x: (size - gs.width) / 2, y: (size - gs.height) / 2, width: gs.width, height: gs.height)
            white.draw(in: drawRect)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let cwd = FileManager.default.currentDirectoryPath
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
let resources = cwd + "/Resources"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)

let plan: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, px) in plan {
    let data = makeIcon(pixels: px)
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "\(resources)/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "✓ Wrote Resources/AppIcon.icns" : "✗ iconutil failed")
