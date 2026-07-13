import SwiftUI
import Foundation

/// Geraldine's Keep Awake mark: a literal eyeball — a bare white sphere, no eyelids —
/// that turns bloodshot. Red veins radiate around the iris and pulse while the Mac is
/// being held awake. Purely decorative, driven by `isActive`; every detail scales with
/// `size` so it reads from 16pt to 120pt.
struct EyeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive

    var isActive: Bool
    var size: CGFloat = 40
    var isPressed = false

    @State private var pulse = false

    private var irisDiameter: CGFloat { size * 0.46 }
    private var pupilDiameter: CGFloat {
        irisDiameter * (isPressed ? 0.40 : (isActive ? 0.56 : 0.48))
    }
    private var lineWidth: CGFloat { max(0.6, size * 0.017) }

    var body: some View {
        ZStack {
            // The eyeball — a white sphere with soft spherical shading.
            Circle()
                .fill(RadialGradient(colors: [.white, Color(white: 0.83)],
                                     center: UnitPoint(x: 0.42, y: 0.40),
                                     startRadius: size * 0.04, endRadius: size * 0.62))

            // Sclera contents clip to the sphere so veins and iris never spill its edge.
            ZStack {
                EyeVeins()
                    .stroke(veinGradient,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .shadow(
                        color: Theme.bad.opacity(reduceMotion ? 0.22 : (pulse ? 0.5 : 0.18)),
                        radius: reduceMotion ? size * 0.025 : (pulse ? size * 0.06 : size * 0.025)
                    )
                    .opacity(isActive ? (reduceMotion ? 0.72 : (pulse ? 1.0 : 0.5)) : 0)

                iris
            }
            .clipShape(Circle())

            Circle()
                .strokeBorder(Color.black.opacity(0.16), lineWidth: max(0.7, size * 0.02))
        }
        .frame(width: size, height: size)
        .animation(GeraldineMotion.animation(.emphasis,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: isActive)
        .animation(GeraldineMotion.animation(.quick,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: isPressed)
        .onAppear(perform: startPulsing)
        .onChange(of: isActive) { _, _ in startPulsing() }
        .onChange(of: reduceMotion) { _, _ in startPulsing() }
        .onChange(of: surfaceActive) { _, _ in startPulsing() }
        .onDisappear { pulse = false }
        .accessibilityLabel(isActive ? "Keep Awake on" : "Keep Awake off")
    }

    private var iris: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: isActive
                                     ? [Color(red: 0.40, green: 0.46, blue: 0.58), Color(red: 0.18, green: 0.23, blue: 0.34)]
                                     : [Color(red: 0.52, green: 0.58, blue: 0.68), Color(red: 0.28, green: 0.34, blue: 0.45)],
                                     center: UnitPoint(x: 0.4, y: 0.35),
                                     startRadius: 0, endRadius: irisDiameter * 0.6))
                .frame(width: irisDiameter, height: irisDiameter)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: max(0.5, size * 0.012)))

            Circle()
                .fill(Color.black.opacity(0.9))
                .frame(width: pupilDiameter, height: pupilDiameter)

            // Catchlight — the spark of life.
            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: irisDiameter * 0.22, height: irisDiameter * 0.22)
                .offset(
                    x: -irisDiameter * (isPressed ? 0.10 : 0.16),
                    y: -irisDiameter * (isPressed ? 0.12 : 0.18)
                )
                .opacity(isPressed ? 0.62 : 0.92)
        }
        .animation(GeraldineMotion.animation(.standard,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: isActive)
        .animation(GeraldineMotion.animation(.quick,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: isPressed)
    }

    private var veinGradient: RadialGradient {
        RadialGradient(colors: [Color(red: 1.0, green: 0.34, blue: 0.34),
                                Color(red: 0.72, green: 0.09, blue: 0.13)],
                       center: .center, startRadius: size * 0.16, endRadius: size * 0.5)
    }

    private func startPulsing() {
        pulse = false
        guard surfaceActive, isActive, !reduceMotion else { return }
        withAnimation(GeraldineMotion.breathing(reduceMotion: false)) {
            pulse = true
        }
    }
}

/// Bloodshot veins radiating inward from the rim toward (but not over) the iris, all the
/// way around the sphere. Generated radially so they distribute evenly without eyelids.
struct EyeVeins: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        func point(angle: Double, frac: CGFloat) -> CGPoint {
            CGPoint(x: center.x + CGFloat(cos(angle)) * frac * radius,
                    y: center.y + CGFloat(sin(angle)) * frac * radius)
        }

        // Irregular angular spacing reads more organic than an even fan.
        let degrees: [Double] = [8, 34, 67, 96, 128, 162, 196, 231, 263, 298, 334]
        for (index, degree) in degrees.enumerated() {
            let angle = degree * .pi / 180
            let lean = (index % 2 == 0 ? 1.0 : -1.0) * 0.17

            // Main vein: a gentle S from near the rim to just outside the iris.
            path.move(to: point(angle: angle, frac: 0.93))
            path.addCurve(to: point(angle: angle, frac: 0.52),
                          control1: point(angle: angle + lean, frac: 0.79),
                          control2: point(angle: angle - lean, frac: 0.64))

            // A short offshoot midway along the vein.
            let branch = (index % 2 == 0 ? 1.0 : -1.0) * 0.30
            path.move(to: point(angle: angle, frac: 0.74))
            path.addQuadCurve(to: point(angle: angle + branch, frac: 0.60),
                              control: point(angle: angle + branch * 0.5, frac: 0.69))
        }
        return path
    }
}
