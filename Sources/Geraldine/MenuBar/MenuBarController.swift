import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let state: AppState
    private var statusItem: NSStatusItem?
    private var monitorSink: AnyCancellable?
    private var layoutSink: AnyCancellable?
    private var currentStatusPlan: StatusPlan?
    private var cancellables = Set<AnyCancellable>()
    private let menuBarRefreshInterval: RunLoop.SchedulerTimeType.Stride = .seconds(2)
    private let menuBarSparklineLimit = 60
    private let statusItemHorizontalPadding: CGFloat = 8
    private let statusAnimationDuration: TimeInterval = 0.24
    private let statusCrossfadeDuration: TimeInterval = 0.14

    private enum StatusAnimationMode {
        case digits
        case crossfade
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

    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(state)
                .environmentObject(state.monitor)
                .environmentObject(state.network)
                .environmentObject(state.devices)
                .environmentObject(state.layout)
                .environmentObject(state.keepAwake)
                .environmentObject(state.calendar)
        )
        return popover
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
            state.setMenuBarPopoverVisible(false)
            popover.close()
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
        button.action = #selector(togglePopover(_:))
        button.toolTip = "Geraldine"
        button.imageScaling = .scaleNone
        button.imagePosition = .imageOnly

        renderStatusItem()

        // Keep sampling/charts at the monitor's cadence, but only redraw the visible
        // menu-bar image about every two seconds. Layout changes stay immediate
        // because the top widget controls what appears in the menu bar.
        // objectWillChange fires *before* values update, so render on the next tick.
        monitorSink = state.monitor.objectWillChange
            .throttle(for: menuBarRefreshInterval, scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor in self?.renderStatusItem() } }
        layoutSink = state.layout.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.renderStatusItem() } }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            state.setMenuBarPopoverVisible(false)
            popover.performClose(sender)
        } else {
            // Refresh the on-demand panels right before the popover appears.
            state.network.refreshWiFi()
            state.devices.refresh()
            state.setMenuBarPopoverVisible(true)
            popover.show(relativeTo: popoverAnchorRect(for: sender), of: sender, preferredEdge: .minY)
            sender.highlight(true)
            popover.contentViewController?.view.window?.makeKey()
            if !popover.isShown { state.setMenuBarPopoverVisible(false) }
        }
    }

    func popoverDidShow(_ notification: Notification) {
        state.setMenuBarPopoverVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        state.setMenuBarPopoverVisible(false)
        statusItem?.button?.highlight(false)
    }

    // MARK: - Status item rendering
    //
    // The live readout is drawn into an NSImage (rather than hosting a SwiftUI view
    // directly inside the status button). Drawing an image is the robust, standard
    // approach used by menu-bar monitors — it sizes and displays reliably, where a
    // hosted custom view can fail to be adopted into the menu bar.

    private struct StatusPlan {
        var kind: MetricKind
        var series: [Double]?     // sparkline values (nil → use glyph)
        var networkSamples: [NetworkSample]? = nil
        var glyph: String?        // SF Symbol name for slow metrics
        var label: String
        var widthSample: String   // widest value this metric can show; fixes the item width
        var color: NSColor        // the value (number) color
        var animationValue: Double?
        var gradient: [NSColor]? = nil   // vertical gradient for the sparkline; nil → derive from color
        var domain: ClosedRange<Double>? = nil
        var valueColor: ((Double) -> NSColor)? = nil
    }

    private func renderStatusItem() {
        guard let button = statusItem?.button else { return }
        let nextPlan = plan()
        let nextImage = drawStatus(nextPlan)
        applyAccessibility(for: nextPlan, to: button)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            statusDisplayLink?.isPaused = true
            clearStatusAnimation()
            applyStatusImage(nextImage, to: button)
            self.currentStatusPlan = nextPlan
            return
        }

        guard let currentStatusPlan else {
            applyStatusImage(nextImage, to: button)
            self.currentStatusPlan = nextPlan
            return
        }

        // A new sample can arrive before a digit roll finishes. Retarget from the
        // image currently on screen so the number never snaps back to the last
        // completed plan. The short dissolve is interruption-safe and keeps the
        // status item's final compact footprint fixed throughout.
        if statusAnimMode != nil {
            animateStatusCrossfade(button: button,
                                   from: button.image ?? drawStatus(currentStatusPlan),
                                   to: nextImage,
                                   targetPlan: nextPlan)
            self.currentStatusPlan = nextPlan
            return
        }

        if currentStatusPlan.kind == nextPlan.kind,
           measurementTokenChanged(from: currentStatusPlan, to: nextPlan) {
            animateStatusCrossfade(button: button,
                                   from: button.image ?? drawStatus(currentStatusPlan),
                                   to: nextImage,
                                   targetPlan: nextPlan)
            self.currentStatusPlan = nextPlan
            return
        }

        if shouldAnimateStatus(from: currentStatusPlan, to: nextPlan) {
            animateStatusItem(button: button, from: currentStatusPlan, to: nextPlan) {}
            self.currentStatusPlan = nextPlan
            return
        }

        if currentStatusPlan.kind != nextPlan.kind {
            animateStatusCrossfade(button: button,
                                   from: button.image ?? drawStatus(currentStatusPlan),
                                   to: nextImage,
                                   targetPlan: nextPlan)
            self.currentStatusPlan = nextPlan
            return
        }

        statusDisplayLink?.isPaused = true
        clearStatusAnimation()
        applyStatusImage(nextImage, to: button)
        self.currentStatusPlan = nextPlan
    }

    private func plan() -> StatusPlan {
        let m = state.monitor
        switch state.layout.menuBarKind(hasBattery: m.hasBattery) {
        case .temperature:
            guard m.thermal.available else {
                return StatusPlan(kind: .temperature, series: thermalUnavailableWaveform, glyph: nil,
                                  label: "", widthSample: "", color: .secondaryLabelColor,
                                  animationValue: nil, domain: 0...1)
            }
            return StatusPlan(kind: .temperature, series: m.thermalHistory.map(\.value), glyph: nil,
                              label: "\(Int(m.thermal.cpu.rounded()))°", widthSample: "888°",
                              color: NSColor(Thermal.color(m.thermal.cpu)),
                              animationValue: m.thermal.cpu,
                              gradient: Thermal.scaleColors.map { NSColor($0) },
                              domain: Thermal.chartDomain,
                              valueColor: { NSColor(Thermal.color($0)) })
        case .cpu:
            return StatusPlan(kind: .cpu, series: m.cpuHistory.map(\.value), glyph: nil,
                              label: Fmt.percent(m.cpuUsage), widthSample: "100%",
                              color: NSColor(MetricChartStyle.readoutColor(for: .cpu)),
                              animationValue: m.cpuUsage * 100,
                              gradient: MetricChartStyle.gradient(for: .cpu)?.map { NSColor($0) },
                              domain: MetricChartStyle.normalizedDomain)
        case .memory:
            return StatusPlan(kind: .memory, series: m.memHistory.map(\.value), glyph: nil,
                              label: Fmt.percent(m.memoryFraction), widthSample: "100%",
                              color: NSColor(MetricChartStyle.readoutColor(for: .memory)),
                              animationValue: m.memoryFraction * 100,
                              gradient: MetricChartStyle.gradient(for: .memory)?.map { NSColor($0) },
                              domain: MetricChartStyle.normalizedDomain)
        case .network:
            return StatusPlan(kind: .network, series: nil, networkSamples: m.networkHistory, glyph: nil,
                              label: "↓\(Fmt.fixedScaled(m.netDown))", widthSample: "↓8888.88M",
                              color: NSColor(Theme.accent2),
                              animationValue: m.netDown)
        case .battery:
            let low = (m.batteryLevel ?? 1) < 0.2
            return StatusPlan(kind: .battery, series: nil, glyph: batteryIcon, label: m.batteryLevel.map(Fmt.percent) ?? "AC",
                              widthSample: "100%",
                              color: NSColor(low ? Theme.bad : MetricChartStyle.readoutColor(for: .battery)),
                              animationValue: m.batteryLevel.map { $0 * 100 })
        case .storage:
            let free = max(0, m.diskTotal - m.diskUsed)
            return StatusPlan(kind: .storage, series: nil, glyph: "internaldrive",
                              label: Fmt.fixedScaled(max(0, m.diskTotal - m.diskUsed)), widthSample: "8888.88G",
                              color: NSColor(MetricChartStyle.readoutColor(for: .storage)),
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

    private func popoverAnchorRect(for button: NSStatusBarButton) -> NSRect {
        let bounds = button.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            return NSRect(x: 0, y: 0,
                          width: max(statusItem?.length ?? 24, 24),
                          height: NSStatusBar.system.thickness)
        }

        // Anchor to the rendered status image instead of the button's full bounds.
        // On recent macOS releases AppKit can report an oversized status-button frame,
        // which makes a popover appear far from the actual menu-bar item.
        if let imageRect = button.cell?.imageRect(forBounds: bounds), imageRect.width > 1 {
            return NSRect(x: imageRect.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
        }
        return bounds
    }

    private func accessibilityValue(for plan: StatusPlan) -> String {
        let m = state.monitor
        switch plan.kind {
        case .temperature:
            guard m.thermal.available else { return "Temperature unavailable" }
            return "Temperature \(Int(m.thermal.cpu.rounded())) degrees Celsius"
        case .cpu:
            return "CPU \(Fmt.percent(m.cpuUsage))"
        case .memory:
            return "Memory \(Fmt.percent(m.memoryFraction))"
        case .network:
            return "Download \(Fmt.rate(m.netDown)), upload \(Fmt.rate(m.netUp))"
        case .battery:
            if let level = m.batteryLevel {
                return "Battery \(Fmt.percent(level))"
            }
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

    /// A persistent, paused display link tied to the status button (an NSView). Created
    /// lazily, runs only while a roll is in flight, and is invalidated when the status
    /// item goes away (see syncVisibility) to break the link's strong ref to its target.
    private func ensureStatusDisplayLink(for button: NSStatusBarButton) {
        guard statusDisplayLink == nil else { return }
        let link = button.displayLink(target: self, selector: #selector(stepStatusAnimation(_:)))
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
        let hasSparkline = plan.series != nil || plan.networkSamples != nil
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
        if let samples = plan.networkSamples {
            drawNetworkSparkline(samples, in: NSRect(x: 0, y: 1, width: geometry.leadingWidth, height: geometry.height - 2),
                                 baseColor: plan.color)
        } else if let series = plan.series {
            drawSparkline(trimmed(series), in: NSRect(x: 0, y: 1, width: geometry.leadingWidth, height: geometry.height - 2),
                          gradient: plan.gradient, baseColor: plan.color, domain: plan.domain, valueColor: plan.valueColor)
        } else if let glyph = plan.glyph, let symbol = tintedSymbol(glyph, color: plan.color) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: 0, y: (geometry.height - size.height) / 2, width: size.width, height: size.height))
        }
    }

    private func drawStaticStatusNumber(_ number: String, color: NSColor, geometry: StatusGeometry) {
        let characters = rightAlignedCharacters(in: number, count: geometry.numberColumnWidths.count)
        for index in characters.indices {
            if let character = characters[index] {
                drawStatusNumberCharacter(character, at: index, color: color, alpha: 1, yOffset: 0, geometry: geometry)
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
    /// absolute thermal domain and threshold-colored line segments; normalized metrics
    /// use fixed 0...1 domains with stable scale gradients.
    private func drawSparkline(_ values: [Double], in rect: NSRect, gradient: [NSColor]?, baseColor: NSColor,
                               domain: ClosedRange<Double>?, valueColor: ((Double) -> NSColor)?) {
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

        let lineColors = gradient ?? [baseColor, baseColor]
        let areaColors = gradient?.map { $0.withAlphaComponent(0.22) }
            ?? [baseColor.withAlphaComponent(0.32), baseColor.withAlphaComponent(0.03)]
        let top = CGPoint(x: rect.midX, y: rect.maxY), bottom = CGPoint(x: rect.midX, y: rect.minY)
        let opts: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

        if let g = makeGradient(areaColors) {
            ctx.saveGState(); ctx.addPath(area); ctx.clip()
            ctx.drawLinearGradient(g, start: top, end: bottom, options: opts)
            ctx.restoreGState()
        }
        if let valueColor {
            ctx.saveGState()
            ctx.setLineWidth(1.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for index in 1..<values.count {
                let segment = CGMutablePath()
                segment.move(to: point(index - 1, values[index - 1]))
                segment.addLine(to: point(index, values[index]))
                ctx.addPath(segment)
                ctx.setStrokeColor(valueColor(max(values[index - 1], values[index])).cgColor)
                ctx.strokePath()
            }
            ctx.restoreGState()
        } else if let g = makeGradient(lineColors) {
            ctx.saveGState()
            ctx.addPath(line)
            ctx.setLineWidth(1.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath(); ctx.clip()
            ctx.drawLinearGradient(g, start: top, end: bottom, options: opts)
            ctx.restoreGState()
        }
    }

    private func drawNetworkSparkline(_ samples: [NetworkSample], in rect: NSRect, baseColor: NSColor) {
        guard samples.count >= 2, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let now = Date().timeIntervalSinceReferenceDate
        let window = SystemMonitor.liveHistoryWindow
        let start = now - window
        let visible = samples.filter { $0.timestamp >= start && $0.timestamp <= now }
        guard visible.count >= 2 else { return }

        let maxValue = max(visible.map { $0.down + $0.up }.max() ?? 0, 1)
        func point(_ sample: NetworkSample) -> CGPoint {
            let x = min(max((sample.timestamp - start) / max(window, 0.001), 0), 1)
            let y = min(max((sample.down + sample.up) / maxValue, 0), 1)
            return CGPoint(x: rect.minX + rect.width * CGFloat(x),
                           y: rect.minY + rect.height * CGFloat(y))
        }

        let line = CGMutablePath()
        let area = CGMutablePath()
        var current: [CGPoint] = []
        var previous: NetworkSample?

        func appendCurrentSegment() {
            guard current.count >= 2, let first = current.first, let last = current.last else { return }
            line.move(to: first)
            area.move(to: CGPoint(x: first.x, y: rect.minY))
            for point in current {
                line.addLine(to: point)
                area.addLine(to: point)
            }
            area.addLine(to: CGPoint(x: last.x, y: rect.minY))
            area.closeSubpath()
        }

        for sample in visible {
            if let previous, sample.timestamp - previous.timestamp > SystemMonitor.chartSampleGapThreshold {
                appendCurrentSegment()
                current.removeAll(keepingCapacity: true)
            }
            current.append(point(sample))
            previous = sample
        }
        appendCurrentSegment()
        guard !line.isEmpty else { return }

        let lineColors = [baseColor.withAlphaComponent(0.68), baseColor]
        let areaColors = [baseColor.withAlphaComponent(0.24), baseColor.withAlphaComponent(0.03)]
        let top = CGPoint(x: rect.midX, y: rect.maxY), bottom = CGPoint(x: rect.midX, y: rect.minY)
        let opts: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

        if let g = makeGradient(areaColors) {
            ctx.saveGState(); ctx.addPath(area); ctx.clip()
            ctx.drawLinearGradient(g, start: top, end: bottom, options: opts)
            ctx.restoreGState()
        }
        if let g = makeGradient(lineColors) {
            ctx.saveGState()
            ctx.addPath(line)
            ctx.setLineWidth(1.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath(); ctx.clip()
            ctx.drawLinearGradient(g, start: top, end: bottom, options: opts)
            ctx.restoreGState()
        }
    }

    private func makeGradient(_ colors: [NSColor]) -> CGGradient? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg = colors.compactMap { $0.usingColorSpace(.sRGB)?.cgColor }
        guard !cg.isEmpty else { return nil }
        let stops = cg.count == 1 ? [cg[0], cg[0]] : cg
        return CGGradient(colorsSpace: space, colors: stops as CFArray, locations: nil)
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

    private func trimmed(_ v: [Double]) -> [Double] {
        if v.count >= 2 { return Array(v.suffix(menuBarSparklineLimit)) }
        return v.isEmpty ? [0, 0] : [v[0], v[0]]
    }

    private var batteryIcon: String {
        if !state.monitor.hasBattery { return "powerplug" }
        if state.monitor.batteryCharging { return "battery.100.bolt" }
        switch state.monitor.batteryLevel ?? 1 {
        case ..<0.15: return "battery.0"
        case ..<0.4:  return "battery.25"
        case ..<0.65: return "battery.50"
        case ..<0.9:  return "battery.75"
        default:      return "battery.100"
        }
    }
}
