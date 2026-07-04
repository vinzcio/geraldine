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

    static func area(under points: [CGPoint], in size: CGSize) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: size.height))
            for pt in points { p.addLine(to: pt) }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }
}

/// Filled sparkline for a series of 0…1 values.
struct SparkGraph: View {
    var values: [Double]
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
        }
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        if values.count >= 2 {
            let points = values.enumerated().map { point($0.offset, $0.element, size) }
            ZStack {
                SparkPath.area(under: points, in: size)
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                SparkPath.line(through: points)
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        } else {
            CollectingHistoryState(tint: tint)
        }
    }

    private func point(_ i: Int, _ v: Double, _ size: CGSize) -> CGPoint {
        let n = max(values.count - 1, 1)
        return CGPoint(x: size.width * CGFloat(i) / CGFloat(n),
                       y: size.height * (1 - CGFloat(min(max(v, 0), 1))))
    }
}

/// Filled sparkline for raw values, scaled to the visible series or a supplied domain.
struct ScaledSparkGraph: View {
    var values: [Double]
    var tint: Color
    /// When set, the line + fill use this fixed vertical gradient (top→bottom)
    /// instead of `tint`, so the chart doesn't recolor as the value changes.
    var gradientColors: [Color]? = nil
    var domain: ClosedRange<Double>?
    var valueColor: ((Double) -> Color)? = nil

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
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
        if values.count >= 2 {
            let points = values.enumerated().map { point($0.offset, $0.element, size) }
            ZStack {
                SparkPath.area(under: points, in: size).fill(areaShading)
                if let valueColor {
                    segmentedLine(points: points, valueColor: valueColor)
                } else {
                    SparkPath.line(through: points)
                        .stroke(lineShading, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        } else {
            CollectingHistoryState(tint: tint)
        }
    }

    private var resolvedDomain: ClosedRange<Double> {
        if let domain { return domain }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let span = max(high - low, 1)
        let padding = max(span * 0.18, 1)
        return (low - padding)...(high + padding)
    }

    private func point(_ i: Int, _ v: Double, _ size: CGSize) -> CGPoint {
        let n = max(values.count - 1, 1)
        let domain = resolvedDomain
        let span = max(domain.upperBound - domain.lowerBound, 1)
        let normalized = min(max((v - domain.lowerBound) / span, 0), 1)
        return CGPoint(x: size.width * CGFloat(i) / CGFloat(n),
                       y: size.height * (1 - CGFloat(normalized)))
    }

    @ViewBuilder
    private func segmentedLine(points: [CGPoint], valueColor: @escaping (Double) -> Color) -> some View {
        ForEach(1..<values.count, id: \.self) { index in
            Path { p in
                p.move(to: points[index - 1])
                p.addLine(to: points[index])
            }
            .stroke(valueColor(max(values[index - 1], values[index])),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Two overlaid line series sharing one vertical scale, so the two magnitudes stay
/// directly comparable (used for the network up/down chart).
struct DualLineGraph: View {
    var primary: [Double]
    var secondary: [Double]
    var primaryTint: Color
    var secondaryTint: Color

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
        }
    }

    private var scale: Double {
        max(primary.max() ?? 0, secondary.max() ?? 0, 1)
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        if primary.count >= 2 || secondary.count >= 2 {
            ZStack {
                series(primary, tint: primaryTint, in: size)
                series(secondary, tint: secondaryTint, in: size)
            }
        } else {
            CollectingHistoryState(tint: primaryTint)
        }
    }

    @ViewBuilder
    private func series(_ values: [Double], tint: Color, in size: CGSize) -> some View {
        if values.count >= 2 {
            let points = values.enumerated().map { point($0.offset, $0.element, values.count, size) }
            SparkPath.area(under: points, in: size)
                .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
            SparkPath.line(through: points)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private func point(_ i: Int, _ v: Double, _ count: Int, _ size: CGSize) -> CGPoint {
        let n = max(count - 1, 1)
        let normalized = min(max(v / scale, 0), 1)
        return CGPoint(x: size.width * CGFloat(i) / CGFloat(n),
                       y: size.height * (1 - CGFloat(normalized)))
    }
}

private struct CollectingHistoryState: View {
    var tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 13, weight: .semibold))
            Text("Collecting history…")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Collecting history")
    }
}

struct DonutSegment: Identifiable {
    let id = UUID()
    var label: String
    var value: Double
    var color: Color
}

/// Segmented donut with a center label. Segments render in order.
struct DonutChart: View {
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
                    .trim(from: r.start, to: max(r.start + 0.001, r.end))
                    .stroke(r.seg.color.gradient,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text(centerTitle).font(.rounded(24, .bold))
                Text(centerSubtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
