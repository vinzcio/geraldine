import SwiftUI

/// Shared path assembly for the spark graphs: a polyline through the points and
/// a closed area path from the same points down to the baseline.
private enum SparkPath {
    static func line(through points: [CGPoint]) -> Path {
        Path { p in
            for (i, pt) in points.enumerated() {
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
        }
    }

    static func area(underSegment points: [CGPoint], baselineY: CGFloat) -> Path {
        Path { p in
            guard let first = points.first, let last = points.last else { return }
            p.move(to: CGPoint(x: first.x, y: baselineY))
            for pt in points { p.addLine(to: pt) }
            p.addLine(to: CGPoint(x: last.x, y: baselineY))
            p.closeSubpath()
        }
    }
}

private enum ChartAccessibility {
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Prepares timeline data without allowing point reduction to erase a real
/// collection gap. Each continuous raw run is reduced independently, preserving
/// the samples on both sides of every gap.
enum TimelineChartRendering {
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

/// Filled single-series sparkline on a fixed time domain. Values retain their actual
/// timestamps, so partial history enters at the right edge and scrolls left over time.
struct TimelineSparkGraph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @FocusState private var accessibilityFocused: Bool
    @State private var accessibilityIndex: Int?
    var samples: [MetricSample]
    var window: TimeInterval
    var now: Date
    var tint: Color
    var gradientColors: [Color]? = nil
    var domain: ClosedRange<Double>?
    var valueColor: ((Double) -> Color)? = nil
    var gapThreshold: TimeInterval = SystemMonitor.chartSampleGapThreshold
    var maximumPointCount: Int? = nil
    var inspectionValueFormatter: ((Double) -> String)? = nil
    var inspectionAccessibilityLabel: String = "Metric history"

    @ViewBuilder
    var body: some View {
        if let inspectionValueFormatter {
            chart
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                        .strokeBorder(accessibilityFocused ? Theme.focusRing : .clear,
                                      lineWidth: 2)
                }
                .contentShape(Rectangle())
                .focusable()
                .focused($accessibilityFocused)
                .focusEffectDisabled()
                .onMoveCommand(perform: moveAccessibilitySelection)
                .onChange(of: accessibilityFocused) { _, isFocused in
                    if isFocused, accessibilityIndex == nil {
                        accessibilityIndex = renderedSamples.indices.last
                    } else if !isFocused {
                        accessibilityIndex = nil
                    }
                }
                .onChange(of: renderedSamples.count) { _, _ in clampAccessibilitySelection() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(inspectionAccessibilityLabel)
                .accessibilityValue(accessibilityValue(formatter: inspectionValueFormatter))
                .accessibilityHint("Use left and right arrow keys, or increment and decrement, to inspect samples.")
                .accessibilityAdjustableAction(adjustAccessibilitySelection)
        } else {
            chart
        }
    }

    private var chart: some View {
        GeometryReader { geo in
            ZStack {
                content(in: geo.size)
                if let inspectionValueFormatter {
                    TimelineInspectionOverlay(
                        samples: renderedSamples,
                        timeline: timeline,
                        domain: resolvedDomain,
                        tint: tint,
                        valueFormatter: inspectionValueFormatter,
                        accessibilitySample: selectedAccessibilitySample
                    )
                }
            }
            .animation(GeraldineMotion.animation(.standard,
                                                 reduceMotion: reduceMotion || !surfaceActive),
                       value: renderedSegments.isEmpty)
        }
    }

    private var selectedAccessibilitySample: MetricSample? {
        guard let accessibilityIndex, renderedSamples.indices.contains(accessibilityIndex) else { return nil }
        return renderedSamples[accessibilityIndex]
    }

    private func accessibilityValue(formatter: (Double) -> String) -> String {
        guard !renderedSamples.isEmpty else { return "Collecting history" }
        let index = min(max(accessibilityIndex ?? (renderedSamples.count - 1), 0), renderedSamples.count - 1)
        let sample = renderedSamples[index]
        return "\(formatter(sample.value)) at \(ChartAccessibility.timeFormatter.string(from: sample.date)), sample \(index + 1) of \(renderedSamples.count)"
    }

    private func adjustAccessibilitySelection(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: stepAccessibilitySelection(by: 1)
        case .decrement: stepAccessibilitySelection(by: -1)
        @unknown default: break
        }
    }

    private func moveAccessibilitySelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .right, .down: stepAccessibilitySelection(by: 1)
        case .left, .up: stepAccessibilitySelection(by: -1)
        @unknown default: break
        }
    }

    private func stepAccessibilitySelection(by offset: Int) {
        guard !renderedSamples.isEmpty else { return }
        let current = accessibilityIndex ?? (renderedSamples.count - 1)
        accessibilityIndex = min(max(current + offset, 0), renderedSamples.count - 1)
    }

    private func clampAccessibilitySelection() {
        guard let accessibilityIndex else { return }
        if renderedSamples.isEmpty {
            self.accessibilityIndex = nil
        } else {
            self.accessibilityIndex = min(accessibilityIndex, renderedSamples.count - 1)
        }
    }

    private var lineShading: AnyShapeStyle {
        if let g = gradientColors {
            return AnyShapeStyle(LinearGradient(colors: g, startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(tint.gradient)
    }

    private var areaShading: AnyShapeStyle {
        if let g = gradientColors {
            return AnyShapeStyle(LinearGradient(colors: g.map { $0.opacity(0.22) },
                                                startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.03)],
                                            startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        let segments = renderedSegments
        if !segments.isEmpty {
            ZStack {
                ChartPlotField(tint: tint)
                series(segments: segments, in: size)
            }
            .transition(.opacity)
        } else {
            CollectingHistoryState(tint: tint)
                .transition(.opacity)
        }
    }

    private var resolvedDomain: ClosedRange<Double> {
        if let domain { return domain }
        guard let low = visibleSamples.map(\.value).min(), let high = visibleSamples.map(\.value).max() else {
            return 0...1
        }
        let span = max(high - low, 1)
        let padding = max(span * 0.18, 1)
        return (low - padding)...(high + padding)
    }

    private var timeline: TimelineWindow {
        TimelineWindow(end: now.timeIntervalSinceReferenceDate, duration: window)
    }

    private var visibleSamples: [MetricSample] {
        timeline.visible(samples)
    }

    private var sampledSegments: [[MetricSample]] {
        TimelineChartRendering.segments(
            samples: visibleSamples,
            timeline: timeline,
            gapThreshold: gapThreshold,
            maximumPointCount: maximumPointCount
        )
    }

    private var renderedSamples: [MetricSample] {
        sampledSegments.flatMap { $0 }
    }

    private var renderedSegments: [[MetricSample]] {
        sampledSegments
    }

    private func point(_ sample: MetricSample, in size: CGSize) -> CGPoint {
        let domain = resolvedDomain
        let span = max(domain.upperBound - domain.lowerBound, 1)
        let normalized = min(max((sample.value - domain.lowerBound) / span, 0), 1)
        return CGPoint(x: size.width * CGFloat(timeline.fraction(for: sample.timestamp)),
                       y: size.height * (1 - CGFloat(normalized)))
    }

    @ViewBuilder
    private func series(segments: [[MetricSample]], in size: CGSize) -> some View {
        ForEach(segments.indices, id: \.self) { index in
            let samples = segments[index]
            let points = samples.map { point($0, in: size) }
            let isLatestSegment = index == segments.indices.last
            if samples.count == 1, let sample = samples.first, let point = points.first {
                if isLatestSegment {
                    ChartEndpoint(point: point, tint: valueColor?(sample.value) ?? tint)
                        .id(sample.timestamp)
                } else {
                    ChartSamplePoint(point: point, tint: valueColor?(sample.value) ?? tint)
                        .id(sample.timestamp)
                }
            } else {
                SparkPath.area(underSegment: points, baselineY: size.height).fill(areaShading)
                if let valueColor {
                    ForEach(1..<samples.count, id: \.self) { sampleIndex in
                        let shading = AnyShapeStyle(
                            valueColor(max(samples[sampleIndex - 1].value, samples[sampleIndex].value))
                        )
                        if isLatestSegment, sampleIndex == samples.count - 1 {
                            ChartLatestSegment(
                                from: points[sampleIndex - 1],
                                to: points[sampleIndex],
                                shading: shading
                            )
                            .id(samples[sampleIndex].timestamp)
                        } else {
                            Path { p in
                                p.move(to: points[sampleIndex - 1])
                                p.addLine(to: points[sampleIndex])
                            }
                            .stroke(shading,
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                    }
                } else if isLatestSegment, points.count >= 2 {
                    if points.count > 2 {
                        SparkPath.line(through: Array(points.dropLast()))
                            .stroke(lineShading,
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    ChartLatestSegment(from: points[points.count - 2],
                                       to: points[points.count - 1],
                                       shading: lineShading)
                        .id(samples.last?.timestamp)
                } else {
                    SparkPath.line(through: points)
                        .stroke(lineShading, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                if isLatestSegment, let last = samples.last {
                    ChartEndpoint(point: point(last, in: size), tint: valueColor?(last.value) ?? tint)
                        .id(last.timestamp)
                }
            }
        }
    }
}

/// Two overlaid network throughput series on a fixed time domain. Unlike the
/// count-based spark graphs, this chart uses sample timestamps for x-positioning
/// so a 5-minute window starts scrolling immediately and preserves sampling gaps.
struct NetworkTimelineGraph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @FocusState private var accessibilityFocused: Bool
    @State private var accessibilityIndex: Int?
    var samples: [NetworkSample]
    var window: TimeInterval
    var now: Date
    var downTint: Color
    var upTint: Color
    var downReference: Double? = nil
    var upReference: Double? = nil
    var gapThreshold: TimeInterval = SystemMonitor.chartSampleGapThreshold
    var showsInspection = false
    var rateUnit: NetworkRateUnit = .bytesPerSecond

    @ViewBuilder
    var body: some View {
        if showsInspection {
            chart
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                        .strokeBorder(accessibilityFocused ? Theme.focusRing : .clear,
                                      lineWidth: 2)
                }
                .contentShape(Rectangle())
                .focusable()
                .focused($accessibilityFocused)
                .focusEffectDisabled()
                .onMoveCommand(perform: moveAccessibilitySelection)
                .onChange(of: accessibilityFocused) { _, isFocused in
                    if isFocused, accessibilityIndex == nil {
                        accessibilityIndex = visibleSamples.indices.last
                    } else if !isFocused {
                        accessibilityIndex = nil
                    }
                }
                .onChange(of: visibleSamples.count) { _, _ in clampAccessibilitySelection() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Network throughput history")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("Use left and right arrow keys, or increment and decrement, to inspect samples.")
                .accessibilityAdjustableAction(adjustAccessibilitySelection)
        } else {
            chart
        }
    }

    private var chart: some View {
        GeometryReader { geo in
            ZStack {
                content(in: geo.size)
                if showsInspection {
                    NetworkInspectionOverlay(
                        samples: visibleSamples,
                        timeline: timeline,
                        downTint: downTint,
                        upTint: upTint,
                        accessibilitySample: selectedAccessibilitySample,
                        rateUnit: rateUnit
                    )
                }
            }
            .animation(GeraldineMotion.animation(.standard,
                                                 reduceMotion: reduceMotion || !surfaceActive),
                       value: segments.isEmpty)
        }
    }

    private var selectedAccessibilitySample: NetworkSample? {
        guard let accessibilityIndex, visibleSamples.indices.contains(accessibilityIndex) else { return nil }
        return visibleSamples[accessibilityIndex]
    }

    private var accessibilityValue: String {
        guard !visibleSamples.isEmpty else { return "Collecting history" }
        let index = min(max(accessibilityIndex ?? (visibleSamples.count - 1), 0), visibleSamples.count - 1)
        let sample = visibleSamples[index]
        return "Download \(Fmt.compactRate(sample.down, unit: rateUnit)), upload \(Fmt.compactRate(sample.up, unit: rateUnit)) at \(ChartAccessibility.timeFormatter.string(from: sample.date)), sample \(index + 1) of \(visibleSamples.count)"
    }

    private func adjustAccessibilitySelection(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: stepAccessibilitySelection(by: 1)
        case .decrement: stepAccessibilitySelection(by: -1)
        @unknown default: break
        }
    }

    private func moveAccessibilitySelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .right, .down: stepAccessibilitySelection(by: 1)
        case .left, .up: stepAccessibilitySelection(by: -1)
        @unknown default: break
        }
    }

    private func stepAccessibilitySelection(by offset: Int) {
        guard !visibleSamples.isEmpty else { return }
        let current = accessibilityIndex ?? (visibleSamples.count - 1)
        accessibilityIndex = min(max(current + offset, 0), visibleSamples.count - 1)
    }

    private func clampAccessibilitySelection() {
        guard let accessibilityIndex else { return }
        if visibleSamples.isEmpty {
            self.accessibilityIndex = nil
        } else {
            self.accessibilityIndex = min(accessibilityIndex, visibleSamples.count - 1)
        }
    }

    private var timeline: TimelineWindow {
        TimelineWindow(end: now.timeIntervalSinceReferenceDate, duration: window)
    }

    private var visibleSamples: [NetworkSample] {
        timeline.visible(samples)
    }

    private func scale(for samples: [NetworkSample]) -> Double {
        let samplePeak = samples.reduce(0) { peak, sample in
            max(peak, sample.down, sample.up)
        }
        return max(samplePeak, downReference ?? 0, upReference ?? 0, 1)
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        let visibleSamples = visibleSamples
        let sampleSegments = TimelineChartRendering.segments(
            samples: visibleSamples,
            timeline: timeline,
            gapThreshold: gapThreshold,
            maximumPointCount: nil
        )
        let chartScale = scale(for: visibleSamples)

        if sampleSegments.isEmpty {
            CollectingHistoryState(tint: downTint)
                .transition(.opacity)
        } else {
            ZStack {
                ChartPlotField(tint: downTint)
                referenceLine(downReference, scale: chartScale, tint: downTint, in: size)
                referenceLine(upReference, scale: chartScale, tint: upTint, in: size)
                series(segments: sampleSegments, value: \.down, scale: chartScale,
                       tint: downTint, in: size)
                series(segments: sampleSegments, value: \.up, scale: chartScale,
                       tint: upTint, in: size)
            }
            .transition(.opacity)
        }
    }

    private var segments: [[NetworkSample]] {
        TimelineChartRendering.segments(
            samples: visibleSamples,
            timeline: timeline,
            gapThreshold: gapThreshold,
            maximumPointCount: nil
        )
    }

    @ViewBuilder
    private func series(segments: [[NetworkSample]], value: KeyPath<NetworkSample, Double>,
                        scale: Double, tint: Color, in size: CGSize) -> some View {
        ForEach(segments.indices, id: \.self) { index in
            let samples = segments[index]
            let points = samples.map { point($0, value: $0[keyPath: value], scale: scale, in: size) }
            let isLatestSegment = index == segments.indices.last
            if samples.count == 1, let point = points.first {
                if isLatestSegment {
                    ChartEndpoint(point: point, tint: tint)
                        .id(samples[0].timestamp)
                } else {
                    ChartSamplePoint(point: point, tint: tint)
                        .id(samples[0].timestamp)
                }
            } else {
                SparkPath.area(underSegment: points, baselineY: size.height)
                    .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                if isLatestSegment, points.count >= 2 {
                    if points.count > 2 {
                        SparkPath.line(through: Array(points.dropLast()))
                            .stroke(tint.gradient,
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    ChartLatestSegment(from: points[points.count - 2],
                                       to: points[points.count - 1],
                                       shading: AnyShapeStyle(tint.gradient))
                        .id(samples.last?.timestamp)
                } else {
                    SparkPath.line(through: points)
                        .stroke(tint.gradient,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if isLatestSegment, let last = points.last {
                    ChartEndpoint(point: last, tint: tint)
                        .id(samples.last?.timestamp)
                }
            }
        }
    }

    @ViewBuilder
    private func referenceLine(_ value: Double?, scale: Double, tint: Color, in size: CGSize) -> some View {
        if let value, value.isFinite, value > 0 {
            let y = size.height * (1 - CGFloat(min(max(value / scale, 0), 1)))
            Path { p in
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
            }
            .stroke(tint.opacity(0.34),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4]))
        }
    }

    private func point(_ sample: NetworkSample, value: Double, scale: Double, in size: CGSize) -> CGPoint {
        let x = timeline.fraction(for: sample.timestamp)
        let y = min(max(value / scale, 0), 1)
        return CGPoint(x: size.width * CGFloat(x),
                       y: size.height * (1 - CGFloat(y)))
    }
}

private struct ChartPlotField: View {
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .fill(tint.opacity(0.025))
                ForEach([CGFloat(0.33), CGFloat(0.66)], id: \.self) { fraction in
                    Path { path in
                        let y = proxy.size.height * fraction
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                    .stroke(Theme.separator.opacity(0.7), style: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ChartSamplePoint: View {
    let point: CGPoint
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 4, height: 4)
            .position(point)
            .accessibilityHidden(true)
    }
}

private struct ChartEndpoint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @State private var revealed = false

    let point: CGPoint
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke(tint.opacity(0.28), lineWidth: 5))
            .shadow(color: tint.opacity(0.30), radius: 4)
            .scaleEffect(reduceMotion || !surfaceActive || revealed ? 1 : 0.72)
            .opacity(reduceMotion || !surfaceActive || revealed ? 1 : 0)
            .position(point)
            .onAppear {
                guard surfaceActive,
                      let animation = GeraldineMotion.animation(.standard, reduceMotion: reduceMotion) else {
                    revealed = true
                    return
                }
                withAnimation(animation) { revealed = true }
            }
            .accessibilityHidden(true)
    }
}

private struct ChartLatestSegment: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @State private var reveal: CGFloat = 0

    let from: CGPoint
    let to: CGPoint
    let shading: AnyShapeStyle

    var body: some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .trim(from: 0, to: reduceMotion || !surfaceActive ? 1 : reveal)
        .stroke(shading,
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .onAppear {
            guard surfaceActive, !reduceMotion,
                  let animation = GeraldineMotion.animation(.standard, reduceMotion: false) else {
                reveal = 1
                return
            }
            withAnimation(animation) { reveal = 1 }
        }
        .accessibilityHidden(true)
    }
}

private struct TimelineInspectionOverlay: View {
    let samples: [MetricSample]
    let timeline: TimelineWindow
    let domain: ClosedRange<Double>
    let tint: Color
    let valueFormatter: (Double) -> String
    let accessibilitySample: MetricSample?

    @State private var location: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let sample = inspectedSample(width: proxy.size.width) {
                    let point = point(for: sample, in: proxy.size)
                    Path { path in
                        path.move(to: CGPoint(x: point.x, y: 0))
                        path.addLine(to: CGPoint(x: point.x, y: proxy.size.height))
                    }
                    .stroke(tint.opacity(0.42), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                        .position(point)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(valueFormatter(sample.value))
                            .font(.caption.weight(.semibold).monospacedDigit())
                        Text(sample.date, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .adaptiveMaterialBackground(
                        .regular,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous).strokeBorder(Theme.separator))
                    .position(
                        x: min(max(point.x, 54), proxy.size.width - 54),
                        y: 24
                    )
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): location = point
                case .ended: location = nil
                }
            }
        }
    }

    private func inspectedSample(width: CGFloat) -> MetricSample? {
        if let location { return nearestSample(to: location.x, width: width) }
        return accessibilitySample
    }

    private func nearestSample(to x: CGFloat, width: CGFloat) -> MetricSample? {
        guard width > 0 else { return nil }
        let target = timeline.start + (Double(min(max(x / width, 0), 1)) * timeline.duration)
        return samples.min { abs($0.timestamp - target) < abs($1.timestamp - target) }
    }

    private func point(for sample: MetricSample, in size: CGSize) -> CGPoint {
        let span = max(domain.upperBound - domain.lowerBound, 0.0001)
        let y = min(max((sample.value - domain.lowerBound) / span, 0), 1)
        return CGPoint(
            x: size.width * CGFloat(timeline.fraction(for: sample.timestamp)),
            y: size.height * (1 - CGFloat(y))
        )
    }
}

private struct NetworkInspectionOverlay: View {
    let samples: [NetworkSample]
    let timeline: TimelineWindow
    let downTint: Color
    let upTint: Color
    let accessibilitySample: NetworkSample?
    let rateUnit: NetworkRateUnit

    @State private var location: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let sample = inspectedSample(width: proxy.size.width) {
                    let x = proxy.size.width * CGFloat(timeline.fraction(for: sample.timestamp))
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    }
                    .stroke(Theme.focusRing.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    VStack(alignment: .leading, spacing: 2) {
                        Label(Fmt.compactRate(sample.down, unit: rateUnit), systemImage: "arrow.down")
                            .foregroundStyle(downTint)
                        Label(Fmt.compactRate(sample.up, unit: rateUnit), systemImage: "arrow.up")
                            .foregroundStyle(upTint)
                        Text(Date(timeIntervalSinceReferenceDate: sample.timestamp), style: .time)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .adaptiveMaterialBackground(
                        .regular,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous).strokeBorder(Theme.separator))
                    .position(x: min(max(x, 58), proxy.size.width - 58), y: 30)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): location = point
                case .ended: location = nil
                }
            }
        }
    }

    private func inspectedSample(width: CGFloat) -> NetworkSample? {
        if let location { return nearestSample(to: location.x, width: width) }
        return accessibilitySample
    }

    private func nearestSample(to x: CGFloat, width: CGFloat) -> NetworkSample? {
        guard width > 0 else { return nil }
        let target = timeline.start + (Double(min(max(x / width, 0), 1)) * timeline.duration)
        return samples.min { abs($0.timestamp - target) < abs($1.timestamp - target) }
    }
}

private struct CollectingHistoryState: View {
    var tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 13, weight: .semibold))
            Text("Collecting History…")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Collecting History")
    }
}

struct DonutSegment: Identifiable {
    var label: String
    var value: Double
    var color: Color

    var id: String { label }
}

/// Segmented donut with a center label. Segments render in order.
struct DonutChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @State private var revealProgress: CGFloat = 0

    var segments: [DonutSegment]
    var centerTitle: String
    var centerSubtitle: String
    var lineWidth: CGFloat = 26

    private var ranges: [(seg: DonutSegment, start: CGFloat, end: CGFloat)] {
        let total = max(segments.reduce(0) { $0 + $1.value }, 0.0001)
        var acc: CGFloat = 0
        return segments.map { seg in
            let start = acc
            acc += CGFloat(seg.value / total)
            return (seg, start, acc)
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.06), lineWidth: lineWidth)
            ForEach(ranges, id: \.seg.id) { r in
                Circle()
                    .trim(
                        from: r.start * revealProgress,
                        to: max((r.start * revealProgress) + 0.001, r.end * revealProgress)
                    )
                    .stroke(r.seg.color.gradient,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text(centerTitle).font(.rounded(24, .bold))
                Text(centerSubtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard surfaceActive, !reduceMotion,
                  let animation = GeraldineMotion.animation(.emphasis, reduceMotion: false) else {
                revealProgress = 1
                return
            }
            withAnimation(animation) { revealProgress = 1 }
        }
        .onDisappear { revealProgress = 0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(centerSubtitle)
        .accessibilityValue(centerTitle)
    }
}
