import AppKit
import SwiftUI
import XCTest
@testable import Geraldine

/// Developer utility, not a regression test: renders the Keep Awake surfaces to PNGs so
/// layout work can be reviewed without driving the live menu bar panel. Runs only when
/// RENDER_SNAPSHOTS=1 and writes into RENDER_SNAPSHOT_DIR (or /tmp/geraldine-snapshots).
@MainActor
final class KeepAwakeSnapshotRenderTests: XCTestCase {
    private var outputDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENDER_SNAPSHOT_DIR"]
            ?? "/tmp/geraldine-snapshots", isDirectory: true)
    }

    func testRenderKeepAwakeSurfaces() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RENDER_SNAPSHOTS"] == "1")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let suiteName = "KeepAwakeSnapshotRenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(KeepAwakeDuration.twelveHours.rawValue, forKey: "keepAwake.defaultDuration")
        defaults.set(true, forKey: "keepAwake.simulateIdleActivity")
        defaults.set(2, forKey: "keepAwake.idleActivityDelayMinutes")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keepAwake = KeepAwakeController(defaults: defaults)
        defer { keepAwake.shutdown() }

        // Grid geometry from the live panel: 640 wide, 16pt outer padding, 4 tracks.
        let gridWidth: CGFloat = 640 - 32
        let track = (gridWidth - 3 * WidgetGridMetrics.spacing) / 4

        try render("widget-small-idle", width: track, height: WidgetGridMetrics.unitHeight) {
            KeepAwakeWidget(size: .small).environmentObject(keepAwake)
        }
        try render("widget-medium-idle", width: track * 2 + WidgetGridMetrics.spacing,
                   height: WidgetGridMetrics.unitHeight) {
            KeepAwakeWidget(size: .medium).environmentObject(keepAwake)
        }
        try render("widget-large-idle", width: gridWidth, height: nil) {
            KeepAwakeWidget(size: .large).environmentObject(keepAwake)
        }

        // Briefly start a real session (released again below) to capture the active layouts.
        keepAwake.toggle()
        // ImageRenderer otherwise captures the first frame of the eye/background transition,
        // which makes unchanged controls look spuriously faded in the developer snapshots.
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        try render("widget-small-active", width: track, height: WidgetGridMetrics.unitHeight) {
            KeepAwakeWidget(size: .small).environmentObject(keepAwake)
        }
        try render("widget-medium-active", width: track * 2 + WidgetGridMetrics.spacing,
                   height: WidgetGridMetrics.unitHeight) {
            KeepAwakeWidget(size: .medium).environmentObject(keepAwake)
        }
        try render("widget-large-active", width: gridWidth, height: nil) {
            KeepAwakeWidget(size: .large).environmentObject(keepAwake)
        }

        // A short synthetic session makes the elapsed/remaining split visible without
        // adding production-only progress injection hooks to KeepAwakeController.
        keepAwake.deactivate()
        keepAwake.activate(duration: 4)
        RunLoop.main.run(until: Date().addingTimeInterval(2.05))
        try render("widget-large-active-half-elapsed", width: gridWidth, height: nil) {
            KeepAwakeWidget(size: .large).environmentObject(keepAwake)
        }
    }

    private func render(_ name: String, width: CGFloat, height: CGFloat?,
                        @ViewBuilder content: () -> some View) throws {
        let view = content()
            .frame(width: width)
            .frame(minHeight: WidgetGridMetrics.unitHeight)
            .frame(height: height)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Could not render \(name)")
            return
        }
        try png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }
}
