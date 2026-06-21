// Extracts evenly-spaced frames from a video + builds a contact sheet.
// Usage: swift Tools/extract_frames.swift <video> <outDir> [count]
import AVFoundation
import AppKit
import Foundation

let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: video outDir [count]"); exit(1) }
let videoPath = a[1]
let outDir = a[2]
let n = a.count > 3 ? (Int(a[3]) ?? 16) : 16

let url = URL(fileURLWithPath: videoPath)
let asset = AVURLAsset(url: url)

var duration: Double = 0
let sem = DispatchSemaphore(value: 0)
Task { if let d = try? await asset.load(.duration) { duration = CMTimeGetSeconds(d) }; sem.signal() }
sem.wait()
if !(duration > 0) { duration = CMTimeGetSeconds(asset.duration) }
guard duration > 0 else { print("could not read duration"); exit(1) }

let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
gen.maximumSize = CGSize(width: 1500, height: 1500)

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

var frames: [(img: NSImage, t: Double)] = []
for i in 0..<n {
    let t = duration * Double(i) / Double(max(1, n - 1))
    let clamped = min(max(0, t), max(0, duration - 0.05))
    let time = CMTime(seconds: clamped, preferredTimescale: 600)
    guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { continue }
    frames.append((NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), clamped))
    if let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/frame_\(String(format: "%02d", i)).png"))
    }
}
print("extracted \(frames.count) frames, duration \(String(format: "%.1f", duration))s")

// Contact sheet
let cols = 4
let rows = Int(ceil(Double(frames.count) / Double(cols)))
let thumbW: CGFloat = 440
let aspect = frames.first.map { $0.img.size.height / max(1, $0.img.size.width) } ?? 0.62
let thumbH = thumbW * aspect
let labelH: CGFloat = 24, pad: CGFloat = 8
let cellW = thumbW + pad * 2, cellH = thumbH + labelH + pad * 2
let sheetW = cellW * CGFloat(cols), sheetH = cellH * CGFloat(rows)

let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
sheet.lockFocus()
NSColor(white: 0.12, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()
for (idx, f) in frames.enumerated() {
    let c = idx % cols, r = idx / cols
    let x = CGFloat(c) * cellW + pad
    let y = sheetH - CGFloat(r + 1) * cellH + pad + labelH
    f.img.draw(in: NSRect(x: x, y: y, width: thumbW, height: thumbH))
    let attrs: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.white,
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
    ]
    "[\(idx)]  \(String(format: "%.1f", f.t))s".draw(at: NSPoint(x: x, y: y - labelH + 3), withAttributes: attrs)
}
sheet.unlockFocus()
if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let data = rep.representation(using: .png, properties: [:]) {
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/contact.png"))
    print("wrote contact.png \(Int(sheetW))x\(Int(sheetH))")
}
