import SwiftUI

/// Keeps a workflow's outer geometry stable while only its local phase content changes.
struct WorkflowPhaseHost<Phase: Hashable, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive

    let phase: Phase
    @ViewBuilder let content: Content

    init(phase: Phase, @ViewBuilder content: () -> Content) {
        self.phase = phase
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .id(phase)
                .transition(GeraldineMotion.stateTransition(reduceMotion: reduceMotion || !surfaceActive))
        }
        .animation(GeraldineMotion.animation(.standard,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: phase)
    }
}

enum WorkflowMarkState: Equatable {
    case idle
    case working
    case success
    case warning
    case failure

    var icon: String {
        switch self {
        case .idle: "sparkle.magnifyingglass"
        case .working: "sparkles"
        case .success: "checkmark"
        case .warning: "exclamationmark"
        case .failure: "xmark"
        }
    }
}

/// One visual anchor that changes locally across ready, working, and result phases.
struct WorkflowMark: View {
    let state: WorkflowMarkState
    let tint: Color
    var idleIcon: String = "sparkle.magnifyingglass"
    var size: CGFloat = 84

    var body: some View {
        ZStack {
            if state == .working {
                BrandSpinner(tint: tint, icon: idleIcon, size: size)
                    .transition(.opacity.combined(with: .scale(scale: GeraldineMotion.iconSwapScale)))
            } else {
                IconBadge(icon: state == .idle ? idleIcon : state.icon,
                          tint: resolvedTint,
                          size: size)
                    .id(state)
                    .transition(.opacity.combined(with: .scale(scale: GeraldineMotion.iconSwapScale)))
            }
        }
        .frame(width: size, height: size)
        .geraldineAnimation(.gentleSpring, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var resolvedTint: Color {
        switch state {
        case .idle, .working: tint
        case .success: Theme.good
        case .warning: Theme.warn
        case .failure: Theme.bad
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: "Ready"
        case .working: "Working"
        case .success: "Complete"
        case .warning: "Needs attention"
        case .failure: "Failed"
        }
    }
}

/// Interruptible fixed-footprint icon replacement. Values mirror the shared
/// interface-polish contract: 0.25 scale, 4-point blur, zero-bounce spring.
struct ContextualSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive

    let inactive: String
    let active: String
    let isActive: Bool
    var tint: Color = Theme.accent
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            symbol(active)
                .opacity(isActive ? 1 : 0)
                .scaleEffect(reduceMotion || !surfaceActive || isActive ? 1 : GeraldineMotion.iconSwapScale)
                .blur(radius: reduceMotion || !surfaceActive || isActive ? 0 : GeraldineMotion.iconSwapBlur)
            symbol(inactive)
                .opacity(isActive ? 0 : 1)
                .scaleEffect(reduceMotion || !surfaceActive || !isActive ? 1 : GeraldineMotion.iconSwapScale)
                .blur(radius: reduceMotion || !surfaceActive || !isActive ? 0 : GeraldineMotion.iconSwapBlur)
        }
        .frame(width: size, height: size)
        .animation(GeraldineMotion.animation(.gentleSpring,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: isActive)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
    }
}

enum OutcomeTone: Equatable {
    case success
    case warning
    case failure

    var tint: Color {
        switch self {
        case .success: Theme.good
        case .warning: Theme.warn
        case .failure: Theme.bad
        }
    }

    var icon: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }
}

private struct OutcomeWashModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    let tone: OutcomeTone?

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(tone.map { Theme.decorativeFill($0.tint) } ?? Color.clear)
            }
            .overlay(alignment: .trailing) {
                if let tone {
                    Image(systemName: tone.icon)
                        .foregroundStyle(tone.tint)
                        .padding(.trailing, Theme.Spacing.sm)
                        .allowsHitTesting(false)
                        .transition(GeraldineMotion.stateTransition(
                            reduceMotion: reduceMotion || !surfaceActive
                        ))
                }
            }
            .animation(GeraldineMotion.animation(.standard,
                                                 reduceMotion: reduceMotion || !surfaceActive),
                       value: tone)
    }
}

extension View {
    func outcomeWash(_ tone: OutcomeTone?) -> some View {
        modifier(OutcomeWashModifier(tone: tone))
    }
}

enum StatefulActionState: Equatable {
    case idle
    case working
    case success
    case failure
}

/// A fixed-geometry action that does not shift when Run becomes Running, Done, or Retry.
struct StatefulActionButton: View {
    let state: StatefulActionState
    let idleTitle: String
    var workingTitle = "Working"
    var successTitle = "Done"
    var failureTitle = "Retry"
    var idleIcon = "play.fill"
    var tint: Color = Theme.accent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if state == .working {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    ContextualSymbol(
                        inactive: idleIcon,
                        active: state == .success ? "checkmark" : "arrow.clockwise",
                        isActive: state == .success || state == .failure,
                        tint: resolvedTint,
                        size: 13
                    )
                    .frame(width: 16, height: 16)
                }
                Text(title)
                    .frame(minWidth: 66, alignment: .leading)
            }
        }
        .buttonStyle(.soft(resolvedTint))
        .disabled(state == .working)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch state {
        case .idle: idleTitle
        case .working: workingTitle
        case .success: successTitle
        case .failure: failureTitle
        }
    }

    private var resolvedTint: Color {
        switch state {
        case .idle, .working: tint
        case .success: Theme.good
        case .failure: Theme.bad
        }
    }
}

enum LedgerStatus: Equatable {
    case neutral
    case selected
    case working
    case success
    case warning
    case failure

    var tone: OutcomeTone? {
        switch self {
        case .success: .success
        case .warning: .warning
        case .failure: .failure
        default: nil
        }
    }
}

/// Shared row language for native Lists. The List keeps keyboard/VoiceOver
/// semantics and virtualization; this view supplies consistent local hierarchy.
/// The leading identity defaults to a `ModuleGlyph`; rows that represent real
/// apps or files can supply their own (app icon plate, monogram, thumbnail).
struct CareLedgerRow<Leading: View, Accessory: View>: View {
    let tint: Color
    let title: String
    let detail: String?
    let status: LedgerStatus
    @ViewBuilder let leading: Leading
    @ViewBuilder let accessory: Accessory

    init(
        tint: Color,
        title: String,
        detail: String? = nil,
        status: LedgerStatus = .neutral,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.tint = tint
        self.title = title
        self.detail = detail
        self.status = status
        self.leading = leading()
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(13, .semibold))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            accessory
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.xs)
        .selectionPlate(isSelected: status == .selected, tint: tint)
        .outcomeWash(status.tone)
        .contentShape(Rectangle())
    }
}

extension CareLedgerRow where Leading == ModuleGlyph {
    init(
        icon: String,
        tint: Color,
        title: String,
        detail: String? = nil,
        status: LedgerStatus = .neutral,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.init(tint: tint, title: title, detail: detail, status: status) {
            ModuleGlyph(systemImage: icon, tint: tint, size: 34)
        } accessory: {
            accessory()
        }
    }
}

extension CareLedgerRow where Leading == ModuleGlyph, Accessory == EmptyView {
    init(
        icon: String,
        tint: Color,
        title: String,
        detail: String? = nil,
        status: LedgerStatus = .neutral
    ) {
        self.init(icon: icon, tint: tint, title: title, detail: detail, status: status) {
            EmptyView()
        }
    }
}
