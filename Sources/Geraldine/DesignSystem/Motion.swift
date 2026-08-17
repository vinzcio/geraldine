import SwiftUI

private struct GeraldineSurfaceActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// True only while the surface that owns a decorative animation is actually visible.
    var geraldineSurfaceActive: Bool {
        get { self[GeraldineSurfaceActiveKey.self] }
        set { self[GeraldineSurfaceActiveKey.self] = newValue }
    }
}

/// One interruption-safe motion grammar for Geraldine.
///
/// Motion communicates continuity or state. It never exists just to make a
/// screen busy, and every path has a quiet Reduce Motion equivalent.
enum GeraldineMotion {
    enum Style {
        case quick
        case standard
        case emphasis
        case gentleSpring
        case ambient
    }

    static let pressScale: CGFloat = 0.96
    static let iconSwapScale: CGFloat = 0.25
    static let iconSwapBlur: CGFloat = 4

    /// Minimum spacing between animated updates of a per-second live metric
    /// (number rolls, ring trims, bar widths). Every in-flight animation runs
    /// the full window render pipeline per frame, so a metric that ticked an
    /// animation every sample kept that pipeline hot ~continuously. Samples
    /// between animated updates apply instantly.
    static let liveMetricAnimationInterval: TimeInterval = 2.5

    static func animation(_ style: Style, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        switch style {
        case .quick:
            return .timingCurve(0.20, 0, 0, 1, duration: 0.14)
        case .standard:
            return .timingCurve(0.20, 0, 0, 1, duration: 0.22)
        case .emphasis:
            return .timingCurve(0.16, 0.78, 0.28, 1, duration: 0.38)
        case .gentleSpring:
            return .spring(duration: 0.34, bounce: 0)
        case .ambient:
            return .easeInOut(duration: 0.9)
        }
    }

    static func spinner(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .linear(duration: 1.1).repeatForever(autoreverses: false)
    }

    static func breathing(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }

    static func pageTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity.combined(with: .offset(y: -5))
        )
    }

    static func moduleTransition(direction: Int, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let sign: CGFloat = direction < 0 ? -1 : 1
        let exit = AnyTransition.opacity
            .combined(with: .offset(x: -sign * 4, y: 0))
            .animation(animation(.quick, reduceMotion: false) ?? .default)
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: sign * 8, y: 0)),
            removal: exit
        )
    }

    static func stateTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .center)),
            removal: .opacity.combined(with: .offset(y: -4))
        )
    }
}

/// Periodic UI updates exist only while their owning window or popover is
/// visible. The frozen branch preserves a readable state without an off-screen
/// timeline continuing to invalidate the SwiftUI tree.
struct GeraldinePeriodicTimeline<Content: View>: View {
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    let start: Date
    let interval: TimeInterval
    let content: (Date) -> Content

    @State private var frozenDate = Date()

    init(from start: Date, by interval: TimeInterval,
         @ViewBuilder content: @escaping (Date) -> Content) {
        self.start = start
        self.interval = interval
        self.content = content
    }

    var body: some View {
        Group {
            if surfaceActive {
                TimelineView(.periodic(from: start, by: interval)) { context in
                    content(context.date)
                }
            } else {
                content(frozenDate)
            }
        }
        .onChange(of: surfaceActive) { _, isActive in
            if !isActive { frozenDate = Date() }
        }
    }
}

private struct GeraldineEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @State private var isVisible = false

    let delay: Double
    let distance: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : distance)
            .blur(radius: reduceMotion || isVisible ? 0 : 4)
            .onAppear {
                if surfaceActive { revealIfNeeded() }
            }
            .onChange(of: surfaceActive) { _, active in
                // Reveal-once: only animate in when the surface first becomes
                // active. Don't reset on inactive — that replayed the entrance
                // every time the window was occluded and re-revealed. Genuine
                // teardown resets @State (isVisible) on its own.
                if active { revealIfNeeded() }
            }
    }

    private func revealIfNeeded() {
        guard !isVisible else { return }
        guard let animation = GeraldineMotion.animation(.emphasis, reduceMotion: reduceMotion) else {
            isVisible = true
            return
        }
        withAnimation(animation.delay(delay)) {
            isVisible = true
        }
    }
}

private struct GeraldineStateChangeModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    let value: Value
    let style: GeraldineMotion.Style

    func body(content: Content) -> some View {
        content.animation(
            GeraldineMotion.animation(style, reduceMotion: reduceMotion || !surfaceActive),
            value: value
        )
    }
}

extension View {
    func geraldineSurfaceActive(_ isActive: Bool) -> some View {
        environment(\.geraldineSurfaceActive, isActive)
    }

    /// A small, split-friendly page entrance. Apply to semantic chunks with
    /// 80–100 ms increments instead of animating one giant container.
    func geraldineEntrance(delay: Double = 0, distance: CGFloat = 10) -> some View {
        modifier(GeraldineEntranceModifier(delay: delay, distance: distance))
    }

    /// Applies the shared animation only when Reduce Motion is off.
    func geraldineAnimation<Value: Equatable>(
        _ style: GeraldineMotion.Style = .standard,
        value: Value
    ) -> some View {
        modifier(GeraldineStateChangeModifier(value: value, style: style))
    }
}
