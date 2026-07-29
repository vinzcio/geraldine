import AppKit
import SwiftUI
import XCTest
@testable import Geraldine

/// Developer utility, not a regression test: renders every metric tile at every size
/// with synthetic monitor data, so small/medium/large layout work can be reviewed as
/// PNGs without driving the live menu-bar panel. Runs only when RENDER_SNAPSHOTS=1
/// and writes into RENDER_SNAPSHOT_DIR (or /tmp/geraldine-snapshots).
@MainActor
final class MetricWidgetSnapshotRenderTests: XCTestCase {
    private struct NullHistoryStore: MonitorHistoryStoring {
        func load() -> MonitorHistorySnapshot? { nil }
        func save(_ snapshot: MonitorHistorySnapshot) throws {}
    }

    private var outputDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENDER_SNAPSHOT_DIR"]
            ?? "/tmp/geraldine-snapshots", isDirectory: true)
    }

    func testRenderMetricWidgetSurfaces() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RENDER_SNAPSHOTS"] == "1")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let suiteName = "MetricWidgetSnapshotRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = SystemMonitor(defaults: defaults,
                                    historyStore: NullHistoryStore(),
                                    performInitialRefresh: false)
        populate(monitor)
        let network = NetworkMonitor()

        // Grid geometry from the live panel: 640 wide, 16pt outer padding, 4 tracks.
        let gridWidth: CGFloat = 640 - 32
        let track = (gridWidth - 3 * WidgetGridMetrics.spacing) / 4

        for metric in MetricKind.allCases {
            for size in WidgetSize.allCases {
                let width: CGFloat
                switch size {
                case .small:  width = track
                case .medium: width = track * 2 + WidgetGridMetrics.spacing
                case .large:  width = gridWidth
                }
                try render("metric-\(metric.rawValue)-\(size.rawValue)",
                           width: width,
                           height: size == .large ? nil : WidgetGridMetrics.unitHeight) {
                    MetricWidget(kind: metric, size: size)
                        .environmentObject(AppState.shared)
                        .environmentObject(monitor)
                        .environmentObject(network)
                }
            }
        }
    }

    /// Deterministic, plausible live data so every tier has something to draw.
    private func populate(_ monitor: SystemMonitor) {
        let now = Date().timeIntervalSinceReferenceDate
        let gib: Double = 1_073_741_824

        monitor.cpuUsage = 0.37
        monitor.memoryTotal = 32 * gib
        monitor.memoryUsed = 21.4 * gib
        monitor.diskTotal = 994 * gib
        monitor.diskUsed = 611 * gib
        monitor.hasBattery = true
        monitor.batteryLevel = 0.68
        monitor.batteryOnAC = false
        monitor.batteryCharging = false
        monitor.batteryMinutesToEmpty = 312
        monitor.batteryHealth = 0.93
        monitor.netDown = 3.2 * 1_048_576
        monitor.netUp = 412 * 1_024
        monitor.thermal = Thermal.Reading(
            cpu: 58, cpuAverage: 55, cpuPeak: 63, hidCPUCandidateCount: 4,
            cpuSource: "HID", peak: 63, battery: 33, storage: 41,
            sensors: [Thermal.Sensor(name: "CPU", temp: 58)]
        )

        func wave(_ tick: Int, base: Double, swing: Double, period: Double) -> Double {
            base + swing * sin(Double(tick) / period)
        }
        monitor.cpuHistory = (0..<60).map {
            MetricSample(timestamp: now - Double(60 - $0),
                         value: wave($0, base: 0.35, swing: 0.22, period: 7))
        }
        monitor.memHistory = (0..<60).map {
            MetricSample(timestamp: now - Double(60 - $0),
                         value: wave($0, base: 0.66, swing: 0.05, period: 11))
        }
        monitor.thermalHistory = (0..<60).map {
            MetricSample(timestamp: now - Double(60 - $0),
                         value: wave($0, base: 57, swing: 6, period: 9))
        }
        monitor.networkHistory = (0..<240).map {
            NetworkSample(timestamp: now - Double(240 - $0),
                          down: max(0, wave($0, base: 2.4, swing: 2.2, period: 13)) * 1_048_576,
                          up: max(0, wave($0, base: 0.5, swing: 0.42, period: 17)) * 1_048_576)
        }
        monitor.batteryHistory = (0..<72).map {
            MetricSample(timestamp: now - Double((72 - $0) * 300),
                         value: min(1, 0.98 - Double($0) * 0.004))
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
