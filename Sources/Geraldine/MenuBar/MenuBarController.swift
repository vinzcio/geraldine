import AppKit
import Combine
import QuartzCore
import SwiftUI

enum MenuBarTimelineRendering {
    static func segments<S: TimelineSample>(
        samples: [S],
        timeline: TimelineWindow,
        gapThreshold: TimeInterval,
        maximumPointCount: Int?
    ) -> [[S]] {
        timeline.segments(samples, gapThreshold: gapThreshold).map { segment in
            timeline.downsample(segment, maximumCount: maximumPointCount)
        }
    }
}

enum MenuBarStatusAnimationPolicy {
    static func shouldShimmer(sameKind: Bool, oldNumber: String, newNumber: String,
                              hasAnimationValues: Bool) -> Bool {
        sameKind &&
        !oldNumber.isEmpty &&
        oldNumber == newNumber &&
        hasAnimationValues
    }
}

enum MenuBarPanelPlacement {
    static let preferredWidth: CGFloat = 640
    static let edgeInset: CGFloat = 10
    static let minimumHeight: CGFloat = 360
    static let initialHeight: CGFloat = 700

    static func frame(in visibleFrame: NSRect, contentHeight: CGFloat) -> NSRect {
        let width = min(preferredWidth, max(1, visibleFrame.width - edgeInset * 2))
        let maximumHeight = max(1, visibleFrame.height - edgeInset * 2)
        let height = min(max(contentHeight, minimumHeight), maximumHeight)
        return NSRect(
            x: visibleFrame.maxX - width - edgeInset,
            y: visibleFrame.maxY - height - edgeInset,
            width: width,
            height: height
        )
    }
}

private final class MenuBarPanel: NSPanel {
    var dismissAction: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        dismissAction?()
    }
}

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private let state: AppState
    private var statusItem: NSStatusItem?
    private var monitorSink: AnyCancellable?
    private var layoutSink: AnyCancellable?
    private var currentStatusPlan: StatusPlan?
    private var cancellables = Set<AnyCancellable>()
    private let menuBarSparklineLimit = 60
    private let menuBarMetricWindow: TimeInterval = 60
    private let statusItemHorizontalPadding: CGFloat = 8
    private let statusAnimationDuration: TimeInterval = 0.24
    private let statusCrossfadeDuration: TimeInterval = 0.14
    private let statusShimmerDuration: TimeInterval = 0.5
    /// Shimmer is a freshness cue, not a metronome: without a cooldown it fires
    /// on every unchanged sample (~1/s), keeping the display link compositing
    /// images half of every second forever.
    private let statusShimmerCooldown: TimeInterval = 10
    private var lastShimmerStart: CFTimeInterval = -.infinity
    private var statusRenderPending = false

    private enum StatusAnimationMode {
        case digits
        case crossfade
        case shimmer
    }

    // Digit-roll animation state. The roll is paced by a persistent, paused
    // CADisplayLink so frames land on real vblanks (no Timer-vs-vsync beat, no
    // per-frame main-actor hop). Everything that doesn't move during a roll —
    // geometry, the split numbers, and the static base image (sparkline / glyph /
    // prefix / suffix) — is computed once here and reused every frame.
    private var statusDisplayLink: CADisplayLink?
    private var statusAnimStart: CFTimeInterval = 0
    private var statusAnimFrom: StatusPlan?
    private var statusAnimTo: StatusPlan?
    private var statusAnimCompletion: (() -> Void)?
    private var statusAnimBase: NSImage?
    private var statusAnimGeometry: StatusGeometry?
    private var statusAnimOldNumber = ""
    private var statusAnimNewNumber = ""
    private var statusAnimMode: StatusAnimationMode?
    private var statusAnimDuration: TimeInterval = 0.24
    private var statusAnimFromImage: NSImage?
    private var statusAnimToImage: NSImage?

    private var panelContentHeight = MenuBarPanelPlacement.initialHeight

    private lazy var panel: MenuBarPanel = {
        let frame = NSRect(
            x: 0,
            y: 0,
            width: MenuBarPanelPlacement.preferredWidth,
            height: MenuBarPanelPlacement.initialHeight
        )
        let panel = MenuBarPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.dismissAction = { [weak self] in self?.hidePanel() }
        panel.contentViewController = NSHostingController(
            rootView: MenuBarView(onContentHeightChange: { [weak self] height in
                self?.panelContentHeightDidChange(height)
            })
                .environmentObject(state)
                .environmentObject(state.monitor)
                .environmentObject(state.network)
                .environmentObject(state.devices)
                .environmentObject(state.layout)
                .environmentObject(state.keepAwake)
                .environmentObject(state.calendar)
                .environmentObject(state.aiUsage)
        )
        return panel
    }()

    init(state: AppState) {
        self.state = state
        super.init()
        observeState()
        syncVisibility()
    }

    private func observeState() {
        state.$appShape
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncVisibility() }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.renderStatusItem() }
            }
            .store(in: &cancellables)
    }

    private func syncVisibility() {
        if state.appShape.showsMenuBar {
            ensureStatusItem()
        } else {
            hidePanel()
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
                self.monitorSink = nil
                self.layoutSink = nil
                self.statusDisplayLink?.invalidate()
                self.statusDisplayLink = nil
                clearStatusAnimation()
                self.currentStatusPlan = nil
            }
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        statusItem = item
        guard let button = item.button else { return }

        button.target = self
        button.action = #selector(togglePanel(_:))
        button.toolTip = "Geraldine"
        button.imageScaling = .scaleNone
        button.imagePosition = .imageOnly

        renderStatusItem()

        #if DEBUG
        runShimmerProbeIfRequested()

        if CommandLine.arguments.contains("--show-menu-panel") {
            DispatchQueue.main.async { [weak self, weak button] in
                guard let self, let button else { return }
                self.showPanel(from: button)
            }
        }
        #endif

        // Render once after each monitor refresh. objectWillChange fires before every
        // published assignment, so the scheduler coalesces that burst onto the next
        // main-loop turn without allowing the menu bar to lag the popover by a sample.
        monitorSink = state.monitor.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.scheduleStatusRender() } }
        layoutSink = state.layout.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.renderStatusItem() } }
    }

    private func scheduleStatusRender() {
        guard !statusRenderPending else { return }
        statusRenderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusRenderPending = false
            self.renderStatusItem()
        }
    }

    #if DEBUG
    /// `--shimmer-probe <dir>`: render the shimmer compositor mid-sweep and
    /// write base/shimmer PNGs for byte-level comparison, bypassing timing,
    /// occlusion, and screen capture entirely.
    private func runShimmerProbeIfRequested() {
        guard let probeIndex = CommandLine.arguments.firstIndex(of: "--shimmer-probe"),
              probeIndex + 1 < CommandLine.arguments.count else { return }
        let dir = CommandLine.arguments[probeIndex + 1]
        let probePlan = plan()
        let geometry = statusGeometry(for: probePlan)
        statusAnimNewNumber = splitLabel(probePlan.label).number
        let base = drawStatus(probePlan)
        let mid = composeStatusShimmer(base: base, plan: probePlan,
                                       geometry: geometry, progress: 0.5)
        for (name, image) in [("base", base), ("shimmer", mid)] {
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/shimmer-probe-\(name).png"))
            }
        }
        statusAnimNewNumber = ""
    }
    #endif

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel(from: sender)
        }
    }

    private func showPanel(from sender: NSStatusBarButton) {
        // Refresh the on-demand panels right before the menu-bar surface appears.
        state.network.refreshWiFi()
        state.devices.refresh()
        state.setMenuBarPopoverVisible(true)
        positionPanel(on: sender.window?.screen ?? NSScreen.main)
        sender.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        if !panel.isVisible { hidePanel() }
    }

    private func positionPanel(on screen: NSScreen?) {
        guard let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        panel.setFrame(
            MenuBarPanelPlacement.frame(in: visibleFrame, contentHeight: panelContentHeight),
            display: true
        )
    }

    private func panelContentHeightDidChange(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        panelContentHeight = height
        guard panel.isVisible else { return }
        positionPanel(on: panel.screen ?? statusItem?.button?.window?.screen)
    }

    private func hidePanel() {
        guard panel.isVisible || state.menuBarPopoverVisible else { return }
        panel.orderOut(nil)
        state.setMenuBarPopoverVisible(false)
        statusItem?.button?.highlight(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, panel.isVisible else { return }
        // A click on the status item resigns the panel before AppKit delivers the
        // button action. Defer one turn so togglePanel can close it instead of seeing
        // an already-hidden panel and immediately reopening it. Ordinary outside
        // clicks still dismiss once their event finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            self.hidePanel()
        }
    }

    // MARK: - Status item rendering
    //
    // The live readout is drawn into an NSImage (rather than hosting a SwiftUI view
    // directly inside the status button). Drawing an image is the robust, standard
    // approach used by menu-bar monitors — it sizes and displays reliably, where a
    // hosted custom view can fail to be adopted into the menu bar.

    private struct StatusTimelineSample: TimelineSample {
        var timestamp: TimeInterval
        var value: Double
        var sessionID: UUID?

        init(_ sample: MetricSample) {
            timestamp = sample.timestamp
            value = sample.value
            sessionID = sample.sessionID
        }

        init(_ sample: NetworkSample) {
            timestamp = sample.timestamp
            value = sample.down
            sessionID = sample.sessionID
        }
    }

    private struct StatusPlan {
        var kind: MetricKind
        var sourceID: UInt64? = nil
        var samples: [StatusTimelineSample]? = nil
        var fallbackSeries: [Double]? = nil
        var timelineDuration: TimeInterval = 60
        var timelineMaximumCount: Int? = nil
        var glyph: String?        // SF Symbol name for slow metrics
        var label: String
        var widthSample: String   // widest value this metric can show; fixes the item width
        var color: NSColor        // the value (number) color
        var animationValue: Double?
        var gradient: MetricGradientSpec? = nil   // vertical gradient for the sparkline; nil -> derive from color
        var areaGradient: MetricGradientSpec? = nil
        var domain: ClosedRange<Double>? = nil
        var zeroBasedDynamicDomain = false
        var sampleColor: ((Double) -> NSColor)? = nil
        var showsLatestEndpoint = true
    }

    private func renderStatusItem() {
        guard let button = statusItem?.button else { return }
        let nextPlan = plan()
        // Drawn lazily: the digit-roll and shimmer branches render their own
        // frames, so an eager draw here would be thrown away on those paths.
        var cachedNextImage: NSImage?
        func nextImage() -> NSImage {
            if let cachedNextImage { return cachedNextImage }
            let image = drawStatus(nextPlan)
            cachedNextImage = image
            return image
        }
        applyAccessibility(for: nextPlan, to: button)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            statusDisplayLink?.isPaused = true
            clearStatusAnimation()
            applyStatusImage(nextImage(), to: button)
            self.currentStatusPlan = nextPlan
            return
        }

        guard let currentStatusPlan else {
            applyStatusImage(nextImage(), to: button)
            self.currentStatusPlan = nextPlan
            return
        }

        if currentStatusPlan.sourceID != nextPlan.sourceID {
            statusDisplayLink?.isPaused = true
            clearStatusAnimation()
            applyStatusImage(nextImage(), to: button)
            self.currentStatusPlan = nextPlan
            return
        }

        // A decorative shimmer must never occupy the animation slot a real value
        // change needs: renders arrive ~2x per second, so an in-flight shimmer
        // would otherwise demote every digit change to the retarget crossfade
        // below and the digit roll would never be seen.
        if statusAnimMode == .shimmer {
            statusDisplayLink?.isPaused = true
            clearStatusAnimation()
        }

        // A new sample can arrive before a digit roll finishes. Retarget from the
        // image currently on screen so the number never snaps back to the last
        // completed plan. The short dissolve is interruption-safe and keeps the
        // status item's final compact footprint fixed throughout.
        if statusAnimMode != nil {
            animateStatusCrossfade(button: button,
                                   from: button.image ?? drawStatus(currentStatusPlan),
                                   to: nextImage(),
                                   targetPlan: nextPlan)
            self.currentStatusPlan = nextPlan
            return
        }

        if currentStatusPlan.kind == nextPlan.kind,
           (measurementTokenChanged(from: currentStatusPlan, to: nextPlan)
            || statusColorChanged(from: currentStatusPlan, to: nextPlan)) {
            animateStatusCrossfade(button: button,
                                   from: button.image ?? drawStatus(currentStatusPlan),
                                   to: nextImage(),
                                   targetPlan: nextPlan)
            self.currentStatusPlan = nextPlan
            return
        }

        if shouldAnimateStatus(from: currentStatusPlan, to: nextPlan) {
            animateStatusItem(button: button, from: currentStatusPlan, to: nextPlan) {}
            self.currentStatusPlan = nextPlan
            return
        }

        if shouldShimmerStatus(from: currentStatusPlan, to: nextPlan),
           CACurrentMediaTime() - lastShimmerStart >= statusShimmerCooldown {
            animateStatusShimmer(button: button, from: currentStatusPlan, to: nextPlan)
            self.currentStatusPlan = nextPlan
            return
        }

        if currentStatusPlan.kind != nextPlan.kind {
            animateStatusCrossfade(button: button,
                                   from: button.image ?? drawStatus(currentStatusPlan),
                                   to: nextImage(),
                                   targetPlan: nextPlan)
            self.currentStatusPlan = nextPlan
            return
        }

        statusDisplayLink?.isPaused = true
        clearStatusAnimation()
        applyStatusImage(nextImage(), to: button)
        self.currentStatusPlan = nextPlan
    }

    private func plan() -> StatusPlan {
        let m = state.monitor
        switch state.layout.menuBarKind(hasBattery: m.hasBattery) {
        case .temperature:
            guard m.thermal.available else {
                let retainedSamples = m.thermalHistory.map(StatusTimelineSample.init)
                return StatusPlan(
                    kind: .temperature,
                    samples: retainedSamples.isEmpty ? nil : retainedSamples,
                    fallbackSeries: retainedSamples.isEmpty ? thermalUnavailableWaveform : nil,
                    timelineDuration: menuBarMetricWindow,
                    timelineMaximumCount: menuBarSparklineLimit,
                    glyph: nil,
                    label: "N/A",
                    widthSample: "888°",
                    color: .secondaryLabelColor,
                    animationValue: nil,
                    gradient: retainedSamples.isEmpty ? nil : Thermal.gradient,
                    domain: retainedSamples.isEmpty ? 0...1 : Thermal.chartDomain,
                    sampleColor: nil,
                    showsLatestEndpoint: false
                )
            }
            return StatusPlan(kind: .temperature,
                              samples: m.thermalHistory.map(StatusTimelineSample.init),
                              timelineDuration: menuBarMetricWindow,
                              timelineMaximumCount: menuBarSparklineLimit,
                              glyph: nil,
                              label: "\(Int(m.thermal.cpu.rounded()))°", widthSample: "888°",
                              color: NSColor(Thermal.readoutColor(m.thermal.cpu)),
                              animationValue: m.thermal.cpu,
                              gradient: Thermal.gradient,
                              domain: Thermal.chartDomain,
                              sampleColor: { NSColor(Thermal.chartColor($0)) })
        case .gpu:
            let device = m.gpuHistory.selectedDevice
            return StatusPlan(kind: .gpu, sourceID: m.gpuHistory.selectedDeviceID,
                              samples: device?.samples.map(StatusTimelineSample.init),
                              timelineDuration: menuBarMetricWindow,
                              timelineMaximumCount: menuBarSparklineLimit,
                              glyph: device?.samples.isEmpty == false ? nil : MetricKind.gpu.icon,
                              label: device?.activity.map(Fmt.percent) ?? "N/A", widthSample: "100%",
                              color: device?.activity.map { NSColor(MetricPresentationPolicy.usageReadoutColor($0)) } ?? .secondaryLabelColor,
                              animationValue: device?.activity.map { $0 * 100 },
                              gradient: MetricChartStyle.gradient(for: .gpu),
                              domain: MetricChartStyle.normalizedDomain,
                              sampleColor: { NSColor(MetricPresentationPolicy.usageChartColor($0)) },
                              showsLatestEndpoint: device?.state == .available)
        case .cpu:
            return StatusPlan(kind: .cpu,
                              samples: m.cpuHistory.map(StatusTimelineSample.init),
                              timelineDuration: menuBarMetricWindow,
                              timelineMaximumCount: menuBarSparklineLimit,
                              glyph: nil,
                              label: Fmt.percent(m.cpuUsage), widthSample: "100%",
                              color: NSColor(MetricPresentationPolicy.usageReadoutColor(m.cpuUsage)),
                              animationValue: m.cpuUsage * 100,
                              gradient: MetricChartStyle.gradient(for: .cpu),
                              domain: MetricChartStyle.normalizedDomain,
                              sampleColor: { NSColor(MetricPresentationPolicy.usageChartColor($0)) })
        case .memory:
            return StatusPlan(kind: .memory,
                              samples: m.memHistory.map(StatusTimelineSample.init),
                              timelineDuration: menuBarMetricWindow,
                              timelineMaximumCount: menuBarSparklineLimit,
                              glyph: nil,
                              label: Fmt.percent(m.memoryFraction), widthSample: "100%",
                              color: NSColor(MetricPresentationPolicy.usageReadoutColor(m.memoryFraction)),
                              animationValue: m.memoryFraction * 100,
                              gradient: MetricChartStyle.gradient(for: .memory),
                              domain: MetricChartStyle.normalizedDomain,
                              sampleColor: { NSColor(MetricPresentationPolicy.usageChartColor($0)) })
        case .network:
            guard state.network.online else {
                return StatusPlan(kind: .network,
                                  glyph: nil,
                                  label: "Offline",
                                  widthSample: "↓8888.88M",
                                  color: NSColor(Theme.warn),
                                  animationValue: nil)
            }
            let color = NSColor(Theme.Chart.blue)
            let rateUnit = selectedNetworkRateUnit
            let displayedDown = rateUnit.displayValue(for: m.netDown)
            return StatusPlan(kind: .network,
                              samples: m.networkHistory.map(StatusTimelineSample.init),
                              timelineDuration: SystemMonitor.liveHistoryWindow,
                              timelineMaximumCount: nil,
                              glyph: nil,
                              label: "↓\(Fmt.fixedScaled(displayedDown))", widthSample: "↓8888.88M",
                              color: color,
                              animationValue: displayedDown,
                              areaGradient: MetricGradientSpec(stops: [
                                  .init(color: Color(nsColor: color.withAlphaComponent(0.24)), location: 0),
                                  .init(color: Color(nsColor: color.withAlphaComponent(0.03)), location: 1)
                              ]),
                              zeroBasedDynamicDomain: true)
        case .battery:
            let label = m.batteryLevel.map(Fmt.percent) ?? (m.hasBattery ? "—" : "AC")
            return StatusPlan(kind: .battery, glyph: batteryIcon, label: label,
                              widthSample: "100%",
                              color: NSColor(MetricPresentationPolicy.batteryReadoutColor(level: m.batteryLevel)),
                              animationValue: m.batteryLevel.map { $0 * 100 })
        case .storage:
            let free = max(0, m.diskTotal - m.diskUsed)
            return StatusPlan(kind: .storage, glyph: "internaldrive",
                              label: Fmt.fixedScaled(max(0, m.diskTotal - m.diskUsed)), widthSample: "8888.88G",
                              color: NSColor(MetricPresentationPolicy.usageReadoutColor(m.diskFraction)),
                              animationValue: free)
        }
    }

    private struct StatusLabelParts {
        var prefix: String
        var number: String
        var suffix: String
    }

    private struct StatusGeometry {
        var height: CGFloat
        var font: NSFont
        var size: NSSize
        var leadingWidth: CGFloat
        var valueOriginX: CGFloat
        var samplePrefixWidth: CGFloat
        var numberColumnWidths: [CGFloat]
        var numberColumnOrigins: [CGFloat]

        var numberWidth: CGFloat {
            numberColumnWidths.reduce(0, +)
        }

        func numberClipRect(at index: Int) -> NSRect {
            let origin = index < numberColumnOrigins.count ? numberColumnOrigins[index] : 0
            let width = index < numberColumnWidths.count ? numberColumnWidths[index] : 0
            return NSRect(x: valueOriginX + samplePrefixWidth + origin - 1,
                   y: 0,
                   width: max(1, width + 2),
                   height: height)
        }

        var suffixOriginX: CGFloat {
            valueOriginX + samplePrefixWidth + numberWidth
        }
    }

    private func drawStatus(_ plan: StatusPlan) -> NSImage {
        let geometry = statusGeometry(for: plan)
        let image = NSImage(size: geometry.size)
        image.lockFocus()
        drawStatusBase(plan, geometry: geometry, includeNumber: true)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func applyAccessibility(for plan: StatusPlan, to button: NSStatusBarButton) {
        button.setAccessibilityLabel("Geraldine status")
        button.setAccessibilityValue(accessibilityValue(for: plan))
        button.setAccessibilityHelp("Open Geraldine")
    }

    private func applyStatusImage(_ image: NSImage, to button: NSStatusBarButton) {
        let width = max(24, ceil(image.size.width + statusItemHorizontalPadding))
        if statusItem?.length != width {
            statusItem?.length = width
        }
        button.image = image
    }

    private func accessibilityValue(for plan: StatusPlan) -> String {
        let m = state.monitor
        switch plan.kind {
        case .temperature:
            guard m.thermal.available else { return "Temperature unavailable" }
            return "Temperature \(Int(m.thermal.cpu.rounded())) degrees Celsius"
        case .gpu:
            let device = m.gpuHistory.selectedDevice
            return "GPU \(device?.displayName ?? "unavailable") \(device?.activity.map(Fmt.percent) ?? device?.state.rawValue ?? "Unavailable")"
        case .cpu:
            return "CPU \(Fmt.percent(m.cpuUsage))"
        case .memory:
            return "Memory \(Fmt.percent(m.memoryFraction))"
        case .network:
            guard state.network.online else { return "Network offline" }
            return "Download \(Fmt.rate(m.netDown, unit: selectedNetworkRateUnit)), upload \(Fmt.rate(m.netUp, unit: selectedNetworkRateUnit))"
        case .battery:
            if let level = m.batteryLevel {
                return "Battery \(Fmt.percent(level))"
            }
            if m.hasBattery { return "Battery level unavailable" }
            return "Power connected"
        case .storage:
            return "Storage \(Fmt.size(max(0, m.diskTotal - m.diskUsed))) free"
        }
    }

    private func shouldAnimateStatus(from old: StatusPlan, to new: StatusPlan) -> Bool {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        let oldNumber = splitLabel(old.label).number
        let newNumber = splitLabel(new.label).number
        return old.kind == new.kind &&
        !oldNumber.isEmpty &&
        !newNumber.isEmpty &&
        hasAnimatedDigitChange(from: oldNumber, to: newNumber) &&
        old.animationValue != nil &&
        new.animationValue != nil
    }

    private func measurementTokenChanged(from old: StatusPlan, to new: StatusPlan) -> Bool {
        let oldParts = splitLabel(old.label)
        let newParts = splitLabel(new.label)
        return oldParts.prefix != newParts.prefix || oldParts.suffix != newParts.suffix
    }

    private func shouldShimmerStatus(from old: StatusPlan, to new: StatusPlan) -> Bool {
        MenuBarStatusAnimationPolicy.shouldShimmer(
            sameKind: old.kind == new.kind,
            oldNumber: splitLabel(old.label).number,
            newNumber: splitLabel(new.label).number,
            hasAnimationValues: old.animationValue != nil && new.animationValue != nil
        )
    }

    /// Rolling old digits over a newly colored chart creates a brief false state at
    /// threshold crossings. A whole-image crossfade keeps each rendered frame's
    /// readout and chart together instead.
    private func statusColorChanged(from old: StatusPlan, to new: StatusPlan) -> Bool {
        guard let oldColor = old.color.usingColorSpace(.sRGB),
              let newColor = new.color.usingColorSpace(.sRGB) else {
            return !old.color.isEqual(new.color)
        }
        let tolerance: CGFloat = 0.001
        return abs(oldColor.redComponent - newColor.redComponent) > tolerance
            || abs(oldColor.greenComponent - newColor.greenComponent) > tolerance
            || abs(oldColor.blueComponent - newColor.blueComponent) > tolerance
            || abs(oldColor.alphaComponent - newColor.alphaComponent) > tolerance
    }

    private func animationDirection(from old: StatusPlan, to new: StatusPlan) -> CGFloat {
        guard let oldValue = old.animationValue, let newValue = new.animationValue else { return 0 }
        if newValue > oldValue { return -1 }
        if newValue < oldValue { return 1 }
        return 0
    }

    private func animateStatusItem(button: NSStatusBarButton, from oldPlan: StatusPlan, to newPlan: StatusPlan,
                                   completion: @escaping () -> Void) {
        // Geometry, the split numbers, and the static base (sparkline / glyph / prefix /
        // suffix) don't change across the roll — render them once here, not per frame.
        let geometry = statusGeometry(for: newPlan, comparing: oldPlan)
        statusAnimGeometry = geometry
        statusAnimOldNumber = splitLabel(oldPlan.label).number
        statusAnimNewNumber = splitLabel(newPlan.label).number
        statusAnimBase = drawStatusBaseImage(newPlan, geometry: geometry)
        statusAnimMode = .digits
        statusAnimDuration = statusAnimationDuration
        statusAnimFromImage = nil
        statusAnimToImage = nil
        statusAnimFrom = oldPlan
        statusAnimTo = newPlan
        statusAnimCompletion = completion
        statusAnimStart = CACurrentMediaTime()
        if statusItem?.length != ceil(geometry.size.width + statusItemHorizontalPadding) {
            statusItem?.length = max(24, ceil(geometry.size.width + statusItemHorizontalPadding))
        }

        ensureStatusDisplayLink(for: button)
        statusDisplayLink?.isPaused = false
    }

    private func animateStatusCrossfade(button: NSStatusBarButton, from oldImage: NSImage,
                                        to newImage: NSImage, targetPlan: StatusPlan) {
        let oldPlan = statusAnimTo ?? currentStatusPlan ?? targetPlan
        statusAnimMode = .crossfade
        statusAnimDuration = statusCrossfadeDuration
        statusAnimFromImage = oldImage.copy() as? NSImage ?? oldImage
        statusAnimToImage = newImage
        statusAnimFrom = oldPlan
        statusAnimTo = targetPlan
        statusAnimBase = nil
        statusAnimGeometry = nil
        statusAnimOldNumber = ""
        statusAnimNewNumber = ""
        statusAnimCompletion = nil
        statusAnimStart = CACurrentMediaTime()

        // Adopt the target width immediately; only pixels dissolve. The status item
        // never interpolates its width or perturbs neighboring menu-bar items.
        let targetWidth = max(24, ceil(newImage.size.width + statusItemHorizontalPadding))
        if statusItem?.length != targetWidth { statusItem?.length = targetWidth }

        ensureStatusDisplayLink(for: button)
        statusDisplayLink?.isPaused = false
    }

    private func animateStatusShimmer(button: NSStatusBarButton, from oldPlan: StatusPlan,
                                      to newPlan: StatusPlan) {
        let geometry = statusGeometry(for: newPlan, comparing: oldPlan)
        statusAnimMode = .shimmer
        statusAnimDuration = statusShimmerDuration
        statusAnimBase = drawStatus(newPlan)
        statusAnimGeometry = geometry
        statusAnimFrom = oldPlan
        statusAnimTo = newPlan
        statusAnimFromImage = nil
        statusAnimToImage = nil
        statusAnimOldNumber = ""
        statusAnimNewNumber = splitLabel(newPlan.label).number
        statusAnimCompletion = nil
        statusAnimStart = CACurrentMediaTime()
        lastShimmerStart = statusAnimStart

        let targetWidth = max(24, ceil(geometry.size.width + statusItemHorizontalPadding))
        if statusItem?.length != targetWidth { statusItem?.length = targetWidth }

        ensureStatusDisplayLink(for: button)
        statusDisplayLink?.isPaused = false
    }

    /// A persistent, paused display link tied to the status button (an NSView). Created
    /// lazily, runs only while a roll is in flight, and is invalidated when the status
    /// item goes away (see syncVisibility) to break the link's strong ref to its target.
    private func ensureStatusDisplayLink(for button: NSStatusBarButton) {
        guard statusDisplayLink == nil else { return }
        let link = button.displayLink(target: self, selector: #selector(stepStatusAnimation(_:)))
        // No preferredFrameRateRange: constraining it to 15-30 on this fixed
        // 60Hz display stopped the link from firing at all, silently killing
        // rolls and shimmers. Animations are short and cadence-gated, so
        // full-rate frames are cheap.
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        statusDisplayLink = link
    }

    @MainActor @objc private func stepStatusAnimation(_ link: CADisplayLink) {
        guard let button = statusItem?.button,
              let mode = statusAnimMode,
              let newPlan = statusAnimTo else {
            link.isPaused = true
            return
        }
        let progress = min(1, (CACurrentMediaTime() - statusAnimStart) / max(statusAnimDuration, 0.001))
        let renderedImage: NSImage
        switch mode {
        case .digits:
            guard let oldPlan = statusAnimFrom,
                  let geometry = statusAnimGeometry,
                  let base = statusAnimBase else {
                link.isPaused = true
                return
            }
            renderedImage = composeAnimatedStatus(base: base, from: oldPlan, to: newPlan,
                                                   geometry: geometry, progress: progress)
        case .crossfade:
            guard let oldImage = statusAnimFromImage,
                  let newImage = statusAnimToImage else {
                link.isPaused = true
                return
            }
            renderedImage = composeStatusCrossfade(from: oldImage, to: newImage, progress: progress)
        case .shimmer:
            guard let base = statusAnimBase,
                  let geometry = statusAnimGeometry else {
                link.isPaused = true
                return
            }
            renderedImage = composeStatusShimmer(base: base, plan: newPlan,
                                                  geometry: geometry, progress: progress)
        }
        applyStatusImage(renderedImage, to: button)
        if progress >= 1 {
            link.isPaused = true
            let completion = statusAnimCompletion
            let finalImage = statusAnimToImage ?? drawStatus(newPlan)
            clearStatusAnimation()
            applyStatusImage(finalImage, to: button)
            completion?()
        }
    }

    private func clearStatusAnimation() {
        statusAnimFrom = nil
        statusAnimTo = nil
        statusAnimBase = nil
        statusAnimGeometry = nil
        statusAnimCompletion = nil
        statusAnimMode = nil
        statusAnimFromImage = nil
        statusAnimToImage = nil
    }

    private func composeStatusCrossfade(from oldImage: NSImage, to newImage: NSImage,
                                        progress: Double) -> NSImage {
        let eased = smoothStep(CGFloat(progress))
        let size = newImage.size
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let oldRect = NSRect(
            x: (size.width - oldImage.size.width) / 2,
            y: (size.height - oldImage.size.height) / 2,
            width: oldImage.size.width,
            height: oldImage.size.height
        )
        oldImage.draw(in: oldRect, from: .zero, operation: .sourceOver, fraction: 1 - eased)
        newImage.draw(in: NSRect(origin: .zero, size: size),
                      from: .zero, operation: .sourceOver, fraction: eased)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func composeStatusShimmer(base: NSImage, plan: StatusPlan,
                                      geometry: StatusGeometry, progress: Double) -> NSImage {
        guard !statusAnimNewNumber.isEmpty else { return base }

        let image = NSImage(size: geometry.size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)

        let numberStart = geometry.valueOriginX + geometry.samplePrefixWidth
        let bandWidth = max(6, min(12, geometry.numberWidth * 0.55))
        let travel = geometry.numberWidth + bandWidth * 2
        let bandStart = numberStart - bandWidth + travel * CGFloat(progress)
        let highlightColor = plan.color.blended(withFraction: 0.72, of: .white) ?? .white
        let sliceCount = 9
        let sliceWidth = bandWidth / CGFloat(sliceCount)

        if let context = NSGraphicsContext.current?.cgContext {
            for slice in 0..<sliceCount {
                let position = (CGFloat(slice) + 0.5) / CGFloat(sliceCount)
                let alpha = sin(position * .pi) * 0.82
                context.saveGState()
                context.clip(to: NSRect(x: bandStart + CGFloat(slice) * sliceWidth,
                                        y: 0, width: sliceWidth + 0.5, height: geometry.height))
                drawStaticStatusNumber(statusAnimNewNumber, color: highlightColor,
                                       alpha: alpha, geometry: geometry)
                context.restoreGState()
            }
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Renders the static layers (sparkline / glyph / prefix / suffix) once per roll.
    private func drawStatusBaseImage(_ plan: StatusPlan, geometry: StatusGeometry) -> NSImage {
        let image = NSImage(size: geometry.size)
        image.lockFocus()
        drawStatusBase(plan, geometry: geometry, includeNumber: false)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Per-frame composite: blit the cached static base 1:1 (no resampling), then draw
    /// only the rolling digit columns on top. Output is identical to redrawing the whole
    /// image each frame, minus the wasted per-frame sparkline/text work.
    private func composeAnimatedStatus(base: NSImage, from oldPlan: StatusPlan, to newPlan: StatusPlan,
                                       geometry: StatusGeometry, progress: Double) -> NSImage {
        guard !statusAnimOldNumber.isEmpty, !statusAnimNewNumber.isEmpty else { return drawStatus(newPlan) }

        let image = NSImage(size: geometry.size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)

        let eased = smoothStep(CGFloat(progress))
        let direction = animationDirection(from: oldPlan, to: newPlan)
        let travel = direction == 0 ? 0 : min(geometry.height * 0.62, 10) * direction
        drawAnimatedStatusNumber(from: statusAnimOldNumber, to: statusAnimNewNumber,
                                 oldColor: oldPlan.color, newColor: newPlan.color,
                                 progress: eased, travel: travel, geometry: geometry)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }

    private func statusGeometry(for plan: StatusPlan, comparing oldPlan: StatusPlan? = nil) -> StatusGeometry {
        let height: CGFloat = 16
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attrs = textAttributes(font: font, color: plan.color)
        let sampleParts = splitLabel(plan.widthSample)
        let labelParts = splitLabel(plan.label)
        let oldParts = oldPlan.map { splitLabel($0.label) }
        let numberColumnCount = max(max(sampleParts.number.count, labelParts.number.count),
                                    oldParts?.number.count ?? 0)
        let sampleNumberCharacters = rightAlignedCharacters(in: sampleParts.number, count: numberColumnCount)
        let numberColumnWidths = sampleNumberCharacters.map { character in
            textWidth(String(character ?? "8"), attrs: attrs)
        }
        var numberColumnOrigins: [CGFloat] = []
        var runningNumberWidth: CGFloat = 0
        for width in numberColumnWidths {
            numberColumnOrigins.append(runningNumberWidth)
            runningNumberWidth += width
        }
        let samplePrefixWidth = textWidth(sampleParts.prefix, attrs: attrs)
        let sampleSuffixWidth = textWidth(sampleParts.suffix, attrs: attrs)
        let valueWidth = samplePrefixWidth + runningNumberWidth + sampleSuffixWidth
        let hasSparkline = plan.samples != nil || plan.fallbackSeries != nil
        let leadingWidth: CGFloat = hasSparkline ? 22 : (plan.glyph != nil ? 14 : 0)
        let gap: CGFloat = (leadingWidth > 0 && valueWidth > 0) ? 4 : 0
        let width = max(12, leadingWidth + gap + valueWidth)

        return StatusGeometry(
            height: height,
            font: font,
            size: NSSize(width: width, height: height),
            leadingWidth: leadingWidth,
            valueOriginX: leadingWidth + gap,
            samplePrefixWidth: samplePrefixWidth,
            numberColumnWidths: numberColumnWidths,
            numberColumnOrigins: numberColumnOrigins
        )
    }

    private func drawStatusBase(_ plan: StatusPlan, geometry: StatusGeometry, includeNumber: Bool) {
        drawStatusLeading(plan, geometry: geometry)

        guard !plan.label.isEmpty else { return }
        let parts = splitLabel(plan.label)
        let attrs = textAttributes(font: geometry.font, color: plan.color)

        guard !parts.number.isEmpty else {
            if includeNumber {
                drawText(plan.label, atX: rightAlignedLabelX(plan.label, geometry: geometry, attrs: attrs),
                         color: plan.color, alpha: 1, yOffset: 0, geometry: geometry)
            }
            return
        }

        if !parts.prefix.isEmpty {
            drawText(parts.prefix, atX: geometry.valueOriginX,
                     color: plan.color, alpha: 1, yOffset: 0, geometry: geometry)
        }
        if includeNumber {
            drawStaticStatusNumber(parts.number, color: plan.color, geometry: geometry)
        }
        if !parts.suffix.isEmpty {
            drawText(parts.suffix, atX: geometry.suffixOriginX,
                     color: plan.color, alpha: 1, yOffset: 0, geometry: geometry)
        }
    }

    private func drawStatusLeading(_ plan: StatusPlan, geometry: StatusGeometry) {
        let rect = NSRect(x: 0, y: 1, width: geometry.leadingWidth, height: geometry.height - 2)
        if let samples = plan.samples {
            drawTimelineSparkline(samples, in: rect,
                                  duration: plan.timelineDuration,
                                  maximumCount: plan.timelineMaximumCount,
                                  gradient: plan.gradient,
                                  areaGradient: plan.areaGradient,
                                  baseColor: plan.color,
                                  domain: plan.domain,
                                  zeroBasedDynamicDomain: plan.zeroBasedDynamicDomain,
                                  sampleColor: plan.sampleColor,
                                  showsLatestEndpoint: plan.showsLatestEndpoint)
        } else if let series = plan.fallbackSeries {
            drawSparkline(trimmed(series), in: NSRect(x: 0, y: 1, width: geometry.leadingWidth, height: geometry.height - 2),
                          gradient: plan.gradient, baseColor: plan.color,
                          domain: plan.domain)
        } else if let glyph = plan.glyph, let symbol = tintedSymbol(glyph, color: plan.color) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: 0, y: (geometry.height - size.height) / 2, width: size.width, height: size.height))
        }
    }

    private func drawStaticStatusNumber(_ number: String, color: NSColor,
                                        alpha: CGFloat = 1, geometry: StatusGeometry) {
        let characters = rightAlignedCharacters(in: number, count: geometry.numberColumnWidths.count)
        for index in characters.indices {
            if let character = characters[index] {
                drawStatusNumberCharacter(character, at: index, color: color, alpha: alpha,
                                          yOffset: 0, geometry: geometry)
            }
        }
    }

    private func drawAnimatedStatusNumber(from oldNumber: String, to newNumber: String,
                                          oldColor: NSColor, newColor: NSColor,
                                          progress: CGFloat, travel: CGFloat,
                                          geometry: StatusGeometry) {
        let count = geometry.numberColumnWidths.count
        let oldCharacters = rightAlignedCharacters(in: oldNumber, count: count)
        let newCharacters = rightAlignedCharacters(in: newNumber, count: count)

        for index in 0..<count {
            let oldCharacter = oldCharacters[index]
            let newCharacter = newCharacters[index]

            if oldCharacter == newCharacter {
                if let newCharacter {
                    drawStatusNumberCharacter(newCharacter, at: index, color: newColor, alpha: 1,
                                              yOffset: 0, geometry: geometry)
                }
            } else if isDigit(oldCharacter), isDigit(newCharacter),
                      let oldCharacter, let newCharacter {
                drawStatusNumberCharacter(oldCharacter, at: index, color: oldColor, alpha: 1 - progress,
                                          yOffset: travel * progress, geometry: geometry)
                drawStatusNumberCharacter(newCharacter, at: index, color: newColor, alpha: progress,
                                          yOffset: -travel * (1 - progress), geometry: geometry)
            } else if isDigit(oldCharacter), newCharacter == nil,
                      let oldCharacter {
                drawStatusNumberCharacter(oldCharacter, at: index, color: oldColor, alpha: 1 - progress,
                                          yOffset: travel * progress, geometry: geometry)
            } else if oldCharacter == nil, isDigit(newCharacter),
                      let newCharacter {
                drawStatusNumberCharacter(newCharacter, at: index, color: newColor, alpha: progress,
                                          yOffset: -travel * (1 - progress), geometry: geometry)
            } else if let newCharacter {
                drawStatusNumberCharacter(newCharacter, at: index, color: newColor, alpha: 1,
                                          yOffset: 0, geometry: geometry)
            }
        }
    }

    private func drawStatusNumberCharacter(_ character: Character, at index: Int, color: NSColor,
                                           alpha: CGFloat, yOffset: CGFloat, geometry: StatusGeometry) {
        guard index < geometry.numberColumnWidths.count, alpha > 0 else { return }
        let text = String(character)
        let attrs = textAttributes(font: geometry.font, color: color)
        let characterWidth = textWidth(text, attrs: attrs)
        let columnOrigin = geometry.numberColumnOrigins[index]
        let columnWidth = geometry.numberColumnWidths[index]
        let x = geometry.valueOriginX + geometry.samplePrefixWidth + columnOrigin + max(0, (columnWidth - characterWidth) / 2)

        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.clip(to: geometry.numberClipRect(at: index))
            drawText(text, atX: x, color: color, alpha: alpha, yOffset: yOffset, geometry: geometry)
            ctx.restoreGState()
        } else {
            drawText(text, atX: x, color: color, alpha: alpha, yOffset: yOffset, geometry: geometry)
        }
    }

    private func drawText(_ text: String, atX x: CGFloat, color: NSColor, alpha: CGFloat,
                          yOffset: CGFloat, geometry: StatusGeometry) {
        guard !text.isEmpty, alpha > 0 else { return }
        let attrs = textAttributes(font: geometry.font, color: color.withAlphaComponent(alpha))
        let textSize = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: x, y: (geometry.height - textSize.height) / 2 + yOffset),
                                withAttributes: attrs)
    }

    private func rightAlignedLabelX(_ label: String, geometry: StatusGeometry,
                                    attrs: [NSAttributedString.Key: Any]) -> CGFloat {
        let textSize = (label as NSString).size(withAttributes: attrs)
        let valueWidth = max(0, geometry.size.width - geometry.valueOriginX)
        return geometry.valueOriginX + max(0, valueWidth - textSize.width)
    }

    private func textAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    private func textWidth(_ text: String, attrs: [NSAttributedString.Key: Any]) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: attrs).width)
    }

    private func hasAnimatedDigitChange(from oldNumber: String, to newNumber: String) -> Bool {
        let count = max(oldNumber.count, newNumber.count)
        let oldCharacters = rightAlignedCharacters(in: oldNumber, count: count)
        let newCharacters = rightAlignedCharacters(in: newNumber, count: count)

        return (0..<count).contains { index in
            oldCharacters[index] != newCharacters[index] &&
            (isDigit(oldCharacters[index]) || isDigit(newCharacters[index]))
        }
    }

    private func rightAlignedCharacters(in text: String, count: Int) -> [Character?] {
        let characters = Array(text)
        let padding = max(0, count - characters.count)
        return Array(repeating: nil, count: padding) + characters.map(Optional.some)
    }

    private func isDigit(_ character: Character?) -> Bool {
        character?.isNumber == true
    }

    private func splitLabel(_ label: String) -> StatusLabelParts {
        guard let numberStart = label.firstIndex(where: { $0.isNumber }) else {
            return StatusLabelParts(prefix: "", number: "", suffix: label)
        }

        var numberEnd = numberStart
        while numberEnd < label.endIndex {
            let character = label[numberEnd]
            if character.isNumber || character == "." || character == "," {
                numberEnd = label.index(after: numberEnd)
            } else {
                break
            }
        }

        return StatusLabelParts(prefix: String(label[..<numberStart]),
                                number: String(label[numberStart..<numberEnd]),
                                suffix: String(label[numberEnd...]))
    }

    /// Draws a filled, gradient sparkline (line + soft area fill). Temperature uses an
    /// absolute thermal domain; normalized metrics use fixed 0...1 domains. Both
    /// render with the same continuous, threshold-positioned scale as SwiftUI.
    private func drawSparkline(_ values: [Double], in rect: NSRect,
                               gradient: MetricGradientSpec?, baseColor: NSColor,
                               domain: ClosedRange<Double>?) {
        guard values.count >= 2, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dLo: Double
        let dSpan: Double
        if let domain {
            dLo = domain.lowerBound
            dSpan = max(domain.upperBound - domain.lowerBound, 0.0001)
        } else {
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            let pad = max((hi - lo) * 0.18, 0.0001)
            dLo = lo - pad
            dSpan = max((hi + pad) - dLo, 0.0001)
        }
        func point(_ i: Int, _ v: Double) -> CGPoint {
            let normalized = min(max((v - dLo) / dSpan, 0), 1)
            return CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1),
                           y: rect.minY + rect.height * CGFloat(normalized))
        }
        let line = CGMutablePath(), area = CGMutablePath()
        line.move(to: point(0, values[0]))
        area.move(to: CGPoint(x: rect.minX, y: rect.minY))
        area.addLine(to: point(0, values[0]))
        for i in 1..<values.count {
            line.addLine(to: point(i, values[i]))
            area.addLine(to: point(i, values[i]))
        }
        area.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        area.closeSubpath()

        let lineGradient = gradient ?? solidGradient(baseColor)
        let areaGradient = gradient?.opacity(0.22)
            ?? twoStopGradient(baseColor.withAlphaComponent(0.32), baseColor.withAlphaComponent(0.03))
        let top = CGPoint(x: rect.midX, y: rect.maxY), bottom = CGPoint(x: rect.midX, y: rect.minY)
        let opts: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

        if let g = makeGradient(areaGradient) {
            ctx.saveGState(); ctx.addPath(area); ctx.clip()
            ctx.drawLinearGradient(g, start: top, end: bottom, options: opts)
            ctx.restoreGState()
        }
        if let g = makeGradient(lineGradient) {
            ctx.saveGState()
            ctx.addPath(line)
            ctx.setLineWidth(1.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath(); ctx.clip()
            ctx.drawLinearGradient(g, start: top, end: bottom, options: opts)
            ctx.restoreGState()
        }
    }

    /// Draws every live status-item chart against elapsed time. Metric histories keep
    /// their compact 60-second window; network keeps its existing five-minute window.
    /// `TimelineWindow.segments` also honors monitor-session boundaries, so persisted
    /// history never connects across an app restart even when the restart is quick.
    private func drawTimelineSparkline(_ samples: [StatusTimelineSample], in rect: NSRect,
                                       duration: TimeInterval, maximumCount: Int?,
                                       gradient: MetricGradientSpec?, areaGradient: MetricGradientSpec?,
                                       baseColor: NSColor, domain: ClosedRange<Double>?,
                                       zeroBasedDynamicDomain: Bool,
                                       sampleColor: ((Double) -> NSColor)?,
                                       showsLatestEndpoint: Bool) {
        guard !samples.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let timeline = TimelineWindow(end: Date().timeIntervalSinceReferenceDate, duration: duration)
        let visible = timeline.visible(samples)
        guard !visible.isEmpty else { return }

        let dLo: Double
        let dSpan: Double
        if let domain {
            dLo = domain.lowerBound
            dSpan = max(domain.upperBound - domain.lowerBound, 0.0001)
        } else if zeroBasedDynamicDomain {
            dLo = 0
            dSpan = max(visible.map(\.value).max() ?? 0, 1)
        } else {
            let lo = visible.map(\.value).min() ?? 0
            let hi = visible.map(\.value).max() ?? 1
            let pad = max((hi - lo) * 0.18, 0.0001)
            dLo = lo - pad
            dSpan = max((hi + pad) - dLo, 0.0001)
        }

        func point(_ sample: StatusTimelineSample) -> CGPoint {
            let normalized = min(max((sample.value - dLo) / dSpan, 0), 1)
            return CGPoint(x: rect.minX + rect.width * CGFloat(timeline.fraction(for: sample.timestamp)),
                           y: rect.minY + rect.height * CGFloat(normalized))
        }

        let line = CGMutablePath()
        let area = CGMutablePath()
        let segments = MenuBarTimelineRendering.segments(
            samples: visible,
            timeline: timeline,
            gapThreshold: SystemMonitor.chartSampleGapThreshold,
            maximumPointCount: maximumCount
        )
        guard !segments.isEmpty else { return }

        let lineSegments = segments.filter { $0.count >= 2 }
        for segment in lineSegments {
            let points = segment.map(point)
            guard let first = points.first, let last = points.last else { continue }
            line.move(to: first)
            area.move(to: CGPoint(x: first.x, y: rect.minY))
            for point in points {
                line.addLine(to: point)
                area.addLine(to: point)
            }
            area.addLine(to: CGPoint(x: last.x, y: rect.minY))
            area.closeSubpath()
        }

        let lineGradient = gradient ?? solidGradient(baseColor)
        let resolvedAreaGradient = areaGradient ?? gradient?.opacity(0.22)
            ?? twoStopGradient(baseColor.withAlphaComponent(0.32), baseColor.withAlphaComponent(0.03))
        let top = CGPoint(x: rect.midX, y: rect.maxY), bottom = CGPoint(x: rect.midX, y: rect.minY)
        let opts: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

        if let g = makeGradient(resolvedAreaGradient) {
            ctx.saveGState(); ctx.addPath(area); ctx.clip()
            ctx.drawLinearGradient(g, start: top, end: bottom, options: opts)
            ctx.restoreGState()
        }
        if let g = makeGradient(lineGradient) {
            ctx.saveGState()
            ctx.addPath(line)
            ctx.setLineWidth(1.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath(); ctx.clip()
            ctx.drawLinearGradient(g, start: top, end: bottom, options: opts)
            ctx.restoreGState()
        }

        // A fresh monitor session starts with one point. Keep that real observation
        // visible as a dot while waiting for the next sample rather than silently
        // presenting the previous session's line as the current one.
        for (index, segment) in segments.enumerated() where segment.count == 1 {
            if index == segments.count - 1, !showsLatestEndpoint { continue }
            let sample = segment[0]
            let center = point(sample)
            let dotColor = sampleColor?(sample.value) ?? baseColor
            ctx.setFillColor(dotColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
        }

        // The endpoint is the visual contract for the adjacent number. Multi-point
        // series need the same state-colored dot that singleton series already get.
        if showsLatestEndpoint,
           let latestSegment = segments.last,
           latestSegment.count >= 2,
           let sample = latestSegment.last {
            let center = point(sample)
            let dotColor = sampleColor?(sample.value) ?? baseColor
            ctx.setFillColor(dotColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
        }
    }

    private func solidGradient(_ color: NSColor) -> MetricGradientSpec {
        twoStopGradient(color, color)
    }

    private func twoStopGradient(_ top: NSColor, _ bottom: NSColor) -> MetricGradientSpec {
        MetricGradientSpec(stops: [
            .init(color: Color(nsColor: top), location: 0),
            .init(color: Color(nsColor: bottom), location: 1)
        ])
    }

    private func makeGradient(_ gradient: MetricGradientSpec) -> CGGradient? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let converted = gradient.stops.compactMap { stop -> (color: CGColor, location: CGFloat)? in
            guard let color = NSColor(stop.color).usingColorSpace(.sRGB)?.cgColor else { return nil }
            return (color, stop.location)
        }
        guard let first = converted.first else { return nil }
        let colors = converted.count == 1 ? [first.color, first.color] : converted.map(\.color)
        let locations = converted.count == 1 ? [CGFloat(0), CGFloat(1)] : converted.map(\.location)
        return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
    }

    private func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = base.withSymbolConfiguration(cfg) ?? base
        image.isTemplate = false
        return image
    }

    // MARK: Data helpers

    private var thermalUnavailableWaveform: [Double] {
        [0.38, 0.48, 0.42, 0.62, 0.34, 0.58, 0.46, 0.54]
    }

    private var selectedNetworkRateUnit: NetworkRateUnit {
        let rawValue = UserDefaults.standard.string(forKey: "networkRateUnit")
        return rawValue.flatMap(NetworkRateUnit.init(rawValue:)) ?? .bytesPerSecond
    }

    private func trimmed(_ v: [Double]) -> [Double] {
        if v.count >= 2 { return Array(v.suffix(menuBarSparklineLimit)) }
        return v.isEmpty ? [0, 0] : [v[0], v[0]]
    }

    private var batteryIcon: String {
        if !state.monitor.hasBattery { return "powerplug" }
        guard let level = state.monitor.batteryLevel else { return "questionmark.circle" }
        if state.monitor.batteryCharging { return "battery.100.bolt" }
        switch level {
        case ..<0.15: return "battery.0"
        case ..<0.4:  return "battery.25"
        case ..<0.65: return "battery.50"
        case ..<0.9:  return "battery.75"
        default:      return "battery.100"
        }
    }
}
