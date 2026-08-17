import SwiftUI

private struct WidgetCustomizationActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var widgetCustomizationActive: Bool {
        get { self[WidgetCustomizationActiveKey.self] }
        set { self[WidgetCustomizationActiveKey.self] = newValue }
    }
}

// MARK: - Grid geometry

/// One source of truth for the popover grid. Both the `Layout` that places tiles and the
/// drag logic that retargets them read frames from here, so they can never disagree about
/// where a tile settles.
enum WidgetGridMetrics {
    static let spacing: CGFloat = 8
    /// One grid unit: every small (1×1) and medium (2×1) tile is exactly this tall,
    /// so rows always line up with no ragged heights.
    static let unitHeight: CGFloat = 132
    /// Below this width the grid falls back to two columns (small = half row).
    static let compactBreakpoint: CGFloat = 520
    static let spaceName = "geraldine.widgetGrid"

    struct Entry {
        let id: String
        /// Logical columns on the wide grid: 1 (small), 2 (medium), or 4 (full width).
        let span: Int
        /// Consulted only for full-width tiles, which take the height their content needs.
        let naturalHeight: CGFloat
    }

    struct Slot {
        let id: String
        let frame: CGRect
    }

    static func columns(for width: CGFloat) -> Int {
        width >= compactBreakpoint ? 4 : 2
    }

    /// Packs entries in order onto the grid — unit-height rows for small/medium tiles,
    /// natural height for full-width rows. Returns one slot per entry, in entry order.
    static func slots(for entries: [Entry], width: CGFloat) -> [Slot] {
        let columns = columns(for: width)
        let track = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var slots: [Slot] = []
        var row: [(entry: Entry, start: Int, span: Int)] = []
        var used = 0
        var y: CGFloat = 0

        func flush() {
            guard !row.isEmpty else { return }
            let natural = row.filter { $0.entry.span >= 4 }.map(\.entry.naturalHeight).max()
            let height = natural.map { max(unitHeight, $0) } ?? unitHeight
            for cell in row {
                let x = CGFloat(cell.start) * (track + spacing)
                let cellWidth = track * CGFloat(cell.span) + spacing * CGFloat(cell.span - 1)
                slots.append(Slot(id: cell.entry.id,
                                  frame: CGRect(x: x, y: y, width: cellWidth, height: height)))
            }
            y += height + spacing
            row = []
            used = 0
        }

        for entry in entries {
            let span = columns == 4 ? min(entry.span, 4) : (entry.span == 1 ? 1 : 2)
            if used + span > columns { flush() }
            row.append((entry, used, span))
            used += span
            if used == columns { flush() }
        }
        flush()
        return slots
    }

    static func height(of slots: [Slot]) -> CGFloat {
        slots.map(\.frame.maxY).max() ?? 0
    }
}

private struct WidgetSpanKey: LayoutValueKey {
    static let defaultValue = 1
}

/// Places each widget at the frame `WidgetGridMetrics` computes for it. Subviews keep a
/// stable identity across reorders, so array mutations reflow with the driving animation.
struct WidgetPackingLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 292
        return CGSize(width: width,
                      height: WidgetGridMetrics.height(of: slots(width: width, subviews: subviews)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        for (subview, slot) in zip(subviews, slots(width: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + slot.frame.minX, y: bounds.minY + slot.frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: slot.frame.width, height: slot.frame.height)
            )
        }
    }

    private func slots(width: CGFloat, subviews: Subviews) -> [WidgetGridMetrics.Slot] {
        // Placement zips positionally, so the packing ids are unused here.
        let entries = subviews.map { subview in
            let span = subview[WidgetSpanKey.self]
            let naturalHeight = span >= 4
                ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                : WidgetGridMetrics.unitHeight
            return WidgetGridMetrics.Entry(id: "", span: span, naturalHeight: naturalHeight)
        }
        return WidgetGridMetrics.slots(for: entries, width: width)
    }
}

// MARK: - Drag state

/// Reports a tile's frame (in grid space) into the drag controller on every layout pass.
private struct WidgetFrameRecorder: View {
    @EnvironmentObject private var drag: WidgetDragController
    let kind: WidgetKind

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(WidgetGridMetrics.spaceName))
            Color.clear
                .onChange(of: frame, initial: true) { _, newFrame in
                    drag.liveFrames[kind] = newFrame
                    if !drag.isDragging {
                        drag.settledHeights[kind] = newFrame.height
                    }
                }
        }
    }
}

// MARK: - Grid

/// The popover's widget dashboard: a uniform four-column grid of 1×1, 2×1, and full-width
/// tiles, with iOS-style drag-to-reorder and per-tile resizing while editing.
struct WidgetGrid: View {
    @EnvironmentObject var layout: WidgetLayoutStore
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var calendar: CalendarSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @State private var customizing = false
    @StateObject private var drag = WidgetDragController()

    var body: some View {
        VStack(spacing: 8) {
            customizationToolbar
            if customizing { customizationPanel }
            widgetRows
        }
        .environment(\.widgetCustomizationActive, customizing)
        .environmentObject(drag)
        .onAppear { configureDragController() }
        .onChange(of: reduceMotion, initial: true) { _, isReduced in
            drag.reduceMotion = isReduced
        }
        .onChange(of: customizing) { _, isCustomizing in
            if !isCustomizing { drag.finalizeIfNeeded() }
        }
        // The popover panel is orderOut-hidden, not torn down, so onDisappear never fires
        // on close — surfaceActive is the reliable "panel closed" signal. A DragGesture
        // cancelled that way calls neither onChanged nor onEnded.
        .onChange(of: surfaceActive) { _, isActive in
            if !isActive { drag.finalizeIfNeeded() }
        }
        // If the dragged tile itself vanishes (widget hidden from another window, battery
        // removed), its gesture dies without onEnded; clear the stuck drag.
        .onChange(of: visibleItems) { _, items in
            if let active = drag.active, !items.contains(where: { $0.kind == active.kind }) {
                drag.finalizeIfNeeded()
            }
        }
        .onDisappear { drag.finalizeIfNeeded() }
    }

    private func configureDragController() {
        drag.layout = layout
        // The stores are app-lifetime singletons; strong captures cannot cycle back
        // through the controller.
        let layout = layout
        let monitor = monitor
        let calendar = calendar
        drag.visibleItems = {
            layout.visibleItems(hasBattery: monitor.hasBattery,
                                calendarInPopover: calendar.appearsInPopover)
        }
    }

    @ViewBuilder private func widget(for item: WidgetItem) -> some View {
        switch item.kind {
        case .metric(let metric): MetricWidget(kind: metric, size: item.size)
        case .keepAwake:          KeepAwakeWidget(size: item.size)
        case .calendar:           CalendarWidget()
        }
    }

    @ViewBuilder private var widgetRows: some View {
        if visibleItems.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "square.grid.2x2")
                Text("No Widgets Selected")
                Spacer()
                Button("Reset") {
                    withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
                        layout.reset()
                    }
                }
                .buttonStyle(.quiet(Theme.accent))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        } else {
            WidgetPackingLayout {
                ForEach(visibleItems) { item in
                    widget(for: item)
                        .layoutValue(key: WidgetSpanKey.self, value: item.size.span)
                        .widgetTileChrome(item, customizing: $customizing)
                }
            }
            // Scoped to the tiles only: the floating tile lives in the overlay ABOVE this
            // modifier so reorders never spring-animate its cursor-tracking position.
            .animation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion),
                       value: visibleItems)
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                    drag.gridWidth = width
                }
            })
            .background(WidgetScrollViewProbe(controller: drag))
            .coordinateSpace(name: WidgetGridMetrics.spaceName)
            .overlay(alignment: .topLeading) { floatingTile }
        }
    }

    @ViewBuilder private var floatingTile: some View {
        if let active = drag.active,
           let item = visibleItems.first(where: { $0.kind == active.kind }) {
            FloatingWidgetTile(drag: drag, pointer: drag.pointer, item: item) { widget(for: $0) }
        }
    }

    private var customizationToolbar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(customizing ? "Edit Widgets" : "At a Glance")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(.primary)
                Text(customizing
                     ? "Drag to reorder. Click the arrows or right-click to resize."
                     : "Live system signals. Drag a tile to rearrange.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if customizing {
                Button {
                    withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
                        layout.reset()
                    }
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.quiet(Theme.accent))
                .help("Reset widget layout")
            }

            Button {
                withAnimation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion)) {
                    customizing.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    ContextualSymbol(
                        inactive: "slider.horizontal.3",
                        active: "checkmark",
                        isActive: customizing,
                        tint: customizing ? Theme.accent : Color(nsColor: .secondaryLabelColor),
                        size: 11
                    )
                    Text(customizing ? "Done" : "Edit")
                }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 9)
                    .frame(minHeight: Theme.Layout.minimumHitArea)
                    .foregroundStyle(customizing ? Theme.accent : .secondary)
            }
            .buttonStyle(.geraldineSelection(Theme.accent,
                                              isSelected: customizing,
                                              cornerRadius: Theme.Radius.pill,
                                              showsSelectionRail: false))
            .help(customizing ? "Finish editing widgets" : "Edit menu bar widgets")
        }
    }

    private var customizationPanel: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(layout.items.filter(isCustomizable)) { item in
                Button {
                    withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
                        layout.setShown(item.kind, !item.isShown)
                    }
                } label: {
                    HStack(spacing: 5) {
                        ContextualSymbol(
                            inactive: "plus.circle",
                            active: "checkmark.circle.fill",
                            isActive: item.isShown,
                            tint: item.isShown ? Theme.accent : Color(nsColor: .secondaryLabelColor),
                            size: 12
                        )
                        Text(item.kind.title(hasBattery: monitor.hasBattery))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer(minLength: 0)
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .frame(minHeight: Theme.Layout.minimumHitArea)
                }
                .buttonStyle(.geraldineSelection(Theme.accent,
                                                  isSelected: item.isShown,
                                                  cornerRadius: Theme.Radius.badge))
                .help(item.isShown ? "Hide \(item.kind.title(hasBattery: monitor.hasBattery))"
                                    : "Show \(item.kind.title(hasBattery: monitor.hasBattery))")
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
    }

    private func isCustomizable(_ item: WidgetItem) -> Bool {
        WidgetLayoutStore.isEligible(item.kind, hasBattery: monitor.hasBattery,
                                     calendarInPopover: calendar.appearsInPopover)
    }

    /// Keep user ordering intact; the packing layout chooses the compact or wide row geometry.
    private var visibleItems: [WidgetItem] {
        layout.visibleItems(hasBattery: monitor.hasBattery,
                            calendarInPopover: calendar.appearsInPopover)
    }
}

// MARK: - Tile chrome (edit mode, drag, resize)

/// Everything a tile gains from living in the grid: frame reporting, edit-mode chrome
/// (inert content + resize badge), the reorder drag gesture, keyboard reordering, a
/// context menu for size and placement, and the hole appearance while its floating
/// copy is being dragged.
private struct WidgetTileChrome: ViewModifier {
    @EnvironmentObject private var layout: WidgetLayoutStore
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var calendar: CalendarSettingsStore
    @EnvironmentObject private var drag: WidgetDragController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Reflected out to the grid so the context menu can enter and leave edit mode.
    @Binding var customizing: Bool
    let item: WidgetItem

    /// Resets the moment the system kills the gesture without `onEnded` (popover
    /// closing, view re-identification) — the controller's cleanup safety net.
    @GestureState private var gestureAlive = false

    func body(content: Content) -> some View {
        let isHole = drag.active?.kind == item.kind
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!customizing)
            .opacity(isHole ? 0 : 1)
            .overlay { if isHole { holePlaceholder } }
            .overlay(alignment: .topTrailing) {
                if customizing && !isHole { resizeBadge }
            }
            .background { WidgetFrameRecorder(kind: item.kind) }
            .contentShape(Rectangle())
            // Direct drag everywhere: 10 pt of travel picks the tile up (clicks and
            // deeper controls stay untouched); edit mode tightens the threshold since
            // tile content is inert there.
            .gesture(dragGesture, including: .all)
            .onChange(of: gestureAlive) { _, alive in
                if !alive { drag.gestureStateDidReset(item.kind) }
            }
            .grabHandCursor(active: customizing && !drag.isDragging)
            .contextMenu { contextMenuItems }
            .focusable(customizing)
            .contentShape(.focusEffect,
                          RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .onMoveCommand { direction in
                guard customizing else { return }
                switch direction {
                case .left, .up: moveEarlier()
                case .right, .down: moveLater()
                @unknown default: break
                }
            }
            .accessibilityElement(children: customizing ? .ignore : .contain)
            .accessibilityLabel(customizing
                                ? "\(item.kind.title(hasBattery: monitor.hasBattery)) widget, \(item.size.label)"
                                : "")
            .accessibilityHint(customizing ? "Use actions to move or resize." : "")
            .accessibilityActions {
                if customizing {
                    Button("Move Earlier") { moveEarlier() }
                    Button("Move Later") { moveLater() }
                    if item.kind.canResize {
                        Button("Resize to \(item.size.next.label)") { cycleSize() }
                    }
                    Button("Hide Widget") { hideWidget() }
                }
            }
    }

    // MARK: Context menu

    @ViewBuilder private var contextMenuItems: some View {
        if item.kind.canResize {
            Picker("Size", selection: sizeSelection) {
                ForEach(WidgetSize.allCases, id: \.self) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.inline)
        }
        Divider()
        Button("Move Earlier") { moveEarlier() }
            .disabled(visibleIndex == 0)
        Button("Move Later") { moveLater() }
            .disabled(visibleIndex == visibleItems.count - 1)
        if item.kind.metric != nil, visibleIndex != 0 {
            // The first metric drives the live status item; surfacing the existing
            // move-to-top behavior makes that discoverable.
            Button("Show in Menu Bar") { moveToFront() }
        }
        Divider()
        Button("Hide Widget") { hideWidget() }
        Button(customizing ? "Done Editing" : "Edit Widgets…") {
            withAnimation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion)) {
                customizing.toggle()
            }
        }
    }

    private var sizeSelection: Binding<WidgetSize> {
        Binding(
            get: { item.size },
            set: { size in
                withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
                    layout.setSize(item.kind, size)
                }
            }
        )
    }

    private var visibleIndex: Int? {
        visibleItems.firstIndex { $0.kind == item.kind }
    }

    private func moveToFront() {
        withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
            layout.moveToFront(item.kind)
        }
    }

    private func hideWidget() {
        withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
            layout.setShown(item.kind, false)
        }
    }

    private var holePlaceholder: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Theme.surfaceMuted)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1))
    }

    @ViewBuilder private var resizeBadge: some View {
        if item.kind.canResize {
            Button(action: cycleSize) {
                Image(systemName: item.size == .large
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(Theme.accent.opacity(0.14), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.accent.opacity(0.30), lineWidth: 1))
            }
            .buttonStyle(.quiet(Theme.accent))
            .minimumHitArea()
            .help("Resize to \(item.size.next.label)")
            .accessibilityLabel("Resize \(item.kind.title(hasBattery: monitor.hasBattery)) to \(item.size.next.label)")
            .transition(.opacity.combined(with: .scale(scale: GeraldineMotion.iconSwapScale)))
        }
    }

    private func cycleSize() {
        withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
            layout.cycleSize(item.kind)
        }
    }

    // MARK: Reorder drag

    /// Pickup thresholds: 4 pt in edit mode (content is inert, dragging is the point),
    /// 10 pt otherwise — enough travel that clicks are never eaten, matching iPadOS
    /// pointer pickup. Deeper controls still win their own gestures, so buttons and
    /// toggles inside a tile stay clickable; grab any quiet region to drag.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: customizing ? 4 : 10,
                    coordinateSpace: .named(WidgetGridMetrics.spaceName))
            .updating($gestureAlive) { _, state, _ in state = true }
            .onChanged { value in drag.dragChanged(item.kind, value: value) }
            .onEnded { value in drag.dragEnded(item.kind, value: value) }
    }

    // MARK: Accessibility & keyboard reorder

    private var visibleItems: [WidgetItem] {
        layout.visibleItems(hasBattery: monitor.hasBattery,
                            calendarInPopover: calendar.appearsInPopover)
    }

    private func moveEarlier() {
        let order = visibleItems.map(\.kind)
        guard let index = order.firstIndex(of: item.kind), index > 0 else { return }
        withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
            layout.move(item.kind, before: order[index - 1])
        }
        announcePosition()
    }

    private func moveLater() {
        let order = visibleItems.map(\.kind)
        guard let index = order.firstIndex(of: item.kind), index + 1 < order.count else { return }
        withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
            layout.move(order[index + 1], before: item.kind)
        }
        announcePosition()
    }

    private func announcePosition() {
        let order = visibleItems.map(\.kind)
        guard let index = order.firstIndex(of: item.kind) else { return }
        let title = item.kind.title(hasBattery: monitor.hasBattery)
        AccessibilityNotification.Announcement(
            "\(title) widget moved to position \(index + 1) of \(order.count)"
        ).post()
    }
}

extension View {
    fileprivate func widgetTileChrome(_ item: WidgetItem, customizing: Binding<Bool>) -> some View {
        modifier(WidgetTileChrome(customizing: customizing, item: item))
    }
}

/// The lifted copy of a dragged widget: follows the cursor 1:1, scales up with a shadow
/// on pickup, and springs into the hole on release — scale and shadow decay with the
/// same settle transaction, so the tile visibly "lands" rather than snapping flat at
/// mouse-up. Observes the pointer object directly so 120 Hz cursor updates re-render
/// only this view, and carries no implicit animation — the lift and settle
/// transactions drive all motion.
private struct FloatingWidgetTile<Content: View>: View {
    @ObservedObject var drag: WidgetDragController
    @ObservedObject var pointer: WidgetDragPointer
    let item: WidgetItem
    @ViewBuilder let content: (WidgetItem) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lifted = false

    var body: some View {
        if let active = drag.active {
            let raised = lifted && !drag.isSettling
            content(item)
                .frame(width: active.size.width, height: active.size.height)
                .scaleEffect(raised && !reduceMotion ? 1.05 : 1)
                .shadow(color: .black.opacity(raised ? 0.26 : 0.10),
                        radius: raised ? 16 : 8,
                        y: raised ? 9 : 4)
                .position(x: pointer.location.x - active.grabOffset.width,
                          y: pointer.location.y - active.grabOffset.height)
                .allowsHitTesting(false)
                .onAppear {
                    guard !reduceMotion else {
                        lifted = true
                        return
                    }
                    withAnimation(.spring(duration: 0.24, bounce: 0.24)) {
                        lifted = true
                    }
                }
        }
    }
}

private struct NetworkRateUnitSlider: View {
    let unit: NetworkRateUnit
    let isCompact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trackWidth: CGFloat { isCompact ? 58 : 64 }
    private let trackHeight: CGFloat = 24
    private let inset: CGFloat = 2
    private var segmentWidth: CGFloat { (trackWidth - inset * 2) / 2 }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.075))

            Capsule()
                .fill(Theme.accent2)
                .frame(width: segmentWidth, height: trackHeight - inset * 2)
                .offset(x: inset + (unit == .bitsPerSecond ? segmentWidth : 0))
                .shadow(color: Theme.accent2.opacity(0.22), radius: 3, y: 1)

            HStack(spacing: 0) {
                label(for: .bytesPerSecond)
                label(for: .bitsPerSecond)
            }
            .padding(.horizontal, inset)
        }
        .frame(width: trackWidth, height: trackHeight)
        .contentShape(Capsule())
        .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion),
                   value: unit)
    }

    private func label(for candidate: NetworkRateUnit) -> some View {
        Text(candidate.compactLabel)
            .font(.system(size: 9, weight: unit == candidate ? .semibold : .medium).monospaced())
            .foregroundStyle(unit == candidate ? Theme.canvas : Color.secondary)
            .frame(width: segmentWidth, height: trackHeight)
    }
}

private struct NetworkRateUnitSliderButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Capsule()
                    .strokeBorder(isFocused ? Theme.focusRing : .clear, lineWidth: 2)
            }
            .minimumHitArea()
            .scaleEffect(configuration.isPressed && !reduceMotion ? GeraldineMotion.pressScale : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .contentShape(Capsule())
            .focusEffectDisabled()
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
            .pointingHandCursor()
    }
}

// MARK: - Widget

/// One resizable, draggable metric tile. Small = compact readout; medium = adds a chart
/// or summary at the shared unit height; large = full-width with a taller chart.
struct MetricWidget: View {
    let kind: MetricKind
    let size: WidgetSize
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var network: NetworkMonitor
    @Environment(\.widgetCustomizationActive) private var customizationActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("networkRateUnit") private var networkRateUnitRawValue = NetworkRateUnit.bytesPerSecond.rawValue
    @State private var freeing = false

    private var isSmall: Bool { size == .small }

    /// One compact rate style for the small and medium tiles (large renders the
    /// Now/Avg/Peak table instead), so the pair always fits beside the speed control.
    private enum NetworkRateStyle {
        static let fontSize: CGFloat = 11
        static let iconWidth: CGFloat = 8
        static let spacing: CGFloat = 2
        static let textWidth: CGFloat = 48
    }

    var body: some View {
        Group {
            if kind == .network { networkBody } else { standardBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(customizationActive ? Theme.accent.opacity(0.24) : .clear, lineWidth: 1))
    }

    // MARK: Shared chrome

    private func headerRow(@ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 5) {
            Image(systemName: kind.icon(hasBattery: monitor.hasBattery)).font(.caption).foregroundStyle(tint)
            Text(kind.title(hasBattery: monitor.hasBattery)).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
    }

    private func actionButton(_ title: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if busy { ProgressView().controlSize(.mini) }
                Text(busy ? "Working…" : title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.quiet(Theme.accent, compact: true)).disabled(busy)
    }

    @ViewBuilder private func caption(_ text: String, animationValue: Double? = nil,
                                      tint: Color = .secondary) -> some View {
        if let animationValue {
            AnimatedNumberText(text, value: animationValue)
                .font(.caption2)
                .foregroundStyle(tint)
                .lineLimit(1)
        } else {
            Text(text)
                .font(.caption2)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }

    // MARK: Standard metrics (temperature / cpu / memory / storage / battery)

    @ViewBuilder private var standardBody: some View {
        VStack(alignment: .leading, spacing: isSmall ? 6 : 8) {
            headerRow {
                // Hidden while editing so the value never sits under the resize badge.
                if !isSmall && !customizationActive {
                    animatedValueText(size: 15, weight: .semibold)
                        .foregroundStyle(chartTint)
                }
            }
            if isSmall { standardSmall } else { standardExpanded }
        }
    }

    /// Small = the hero value plus a micro-trend: live metrics get a compact sparkline
    /// (the same series their larger tiers chart), storage keeps its capacity bar —
    /// its short-term history is a flat line, so the fraction is the story.
    @ViewBuilder private var standardSmall: some View {
        animatedValueText(size: 16, weight: .semibold)
            .foregroundStyle(chartTint)
        if kind == .battery {
            normalizedHistoryChart(window: MetricChartStyle.smallWindow,
                                   maximumPointCount: MetricChartStyle.smallMaxPoints)
                .frame(height: 28)
        } else if kind == .storage {
            StatBar(fraction: fraction, tint: chartTint, height: 6)
        } else {
            chart.frame(height: 28)
        }
        Spacer(minLength: 0)
        smallFooter
            .frame(height: Theme.Layout.compactHitArea)
    }

    /// Every small tile shares one footer rhythm: a fixed-height strip with a caption on
    /// the left and the quiet action trailing — so captions and actions line up tile to tile.
    @ViewBuilder private var smallFooter: some View {
        switch kind {
        case .temperature:
            caption(monitor.thermal.available ? "CPU Die" : "Unavailable")
        case .cpu:
            HStack {
                caption("In Use")
                Spacer(minLength: 4)
                actionButton("Details") { state.open(.activity) }
            }
        case .memory:
            HStack {
                caption("In Use")
                Spacer(minLength: 4)
                actionButton("Free Up", busy: freeing) { freeMemory() }
            }
        case .storage:
            HStack {
                caption("\(Fmt.percent(monitor.diskFraction)) Used",
                        animationValue: monitor.diskFraction * 100,
                        tint: chartTint)
                Spacer(minLength: 4)
                actionButton("Review") { state.open(.storage) }
            }
        case .battery:     caption(batteryCaption, animationValue: batteryCaptionAnimationValue)
        case .network:     EmptyView()
        }
    }

    /// Medium fills the shared unit height with a flexible chart; large (full width) gets
    /// a taller fixed chart and takes the height it needs. The footer is a fixed-height
    /// strip so every tile's chart resolves to the same height side by side.
    @ViewBuilder private var standardExpanded: some View {
        if kind == .storage {
            if size == .large {
                storageCapacityDetail
                    .frame(maxHeight: .infinity)
            } else {
                storageCapacitySummary
                    .frame(maxHeight: .infinity)
            }
        } else if size == .large {
            chart.frame(height: 148)
        } else {
            chart.frame(maxHeight: .infinity)
        }
        largeFooter
            .frame(height: Theme.Layout.compactHitArea)
    }

    private var storageCapacitySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatBar(fraction: monitor.diskFraction, tint: chartTint, height: 8)
            HStack(spacing: 16) {
                caption("\(Fmt.size(monitor.diskUsed)) Used", animationValue: monitor.diskUsed,
                        tint: chartTint)
                Spacer(minLength: 4)
                caption("\(Fmt.percent(monitor.diskFraction)) Full",
                        animationValue: monitor.diskFraction * 100,
                        tint: chartTint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The full-width tier earns more than a stretched bar: the same hero fraction,
    /// then a labeled Used / Free / Capacity readout row.
    private var storageCapacityDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatBar(fraction: monitor.diskFraction, tint: chartTint, height: 10)
            HStack(alignment: .top, spacing: 24) {
                storageStat("Used", value: monitor.diskUsed, tint: chartTint)
                storageStat("Free", value: max(0, monitor.diskTotal - monitor.diskUsed),
                            tint: .primary)
                storageStat("Capacity", value: monitor.diskTotal, tint: .secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func storageStat(_ label: String, value: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            AnimatedNumberText(Fmt.size(value), value: value)
                .font(.rounded(15, .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder private var chart: some View {
        switch kind {
        case .temperature:
            liveHistoryChart(samples: monitor.thermalHistory,
                             tint: monitor.thermal.available
                                ? MetricChartStyle.chartColor(for: .temperature)
                                : .secondary,
                             gradient: Thermal.gradient,
                             domain: Thermal.chartDomain,
                             sampleColor: monitor.thermal.available ? Thermal.chartColor : nil,
                             showsLatestEndpoint: monitor.thermal.available)
        case .cpu:
            liveHistoryChart(samples: monitor.cpuHistory,
                             tint: MetricChartStyle.chartColor(for: .cpu),
                             gradient: MetricChartStyle.gradient(for: .cpu),
                             domain: MetricChartStyle.normalizedDomain,
                             sampleColor: MetricPresentationPolicy.usageChartColor)
        case .memory:
            liveHistoryChart(samples: monitor.memHistory,
                             tint: MetricChartStyle.chartColor(for: .memory),
                             gradient: MetricChartStyle.gradient(for: .memory),
                             domain: MetricChartStyle.normalizedDomain,
                             sampleColor: MetricPresentationPolicy.usageChartColor)
        case .battery:
            normalizedHistoryChart(window: MetricChartStyle.expandedWindow,
                                   maximumPointCount: MetricChartStyle.expandedMaxPoints)
        case .storage:
            EmptyView()
        case .network:
            EmptyView()
        }
    }

    private func liveHistoryChart(samples: [MetricSample], tint: Color,
                                  gradient: MetricGradientSpec?, domain: ClosedRange<Double>,
                                  sampleColor: ((Double) -> Color)? = nil,
                                  showsLatestEndpoint: Bool = true) -> some View {
        TimelineSparkGraph(samples: samples,
                           window: SystemMonitor.liveHistoryWindow,
                           now: Date(),
                           tint: tint,
                           gradient: gradient,
                           domain: domain,
                           sampleColor: sampleColor,
                           showsLatestEndpoint: showsLatestEndpoint,
                           gapThreshold: SystemMonitor.chartSampleGapThreshold,
                           maximumPointCount: 300)
    }

    private func normalizedHistoryChart(window: TimeInterval, maximumPointCount: Int) -> some View {
        let now = Date()
        let samples = kind == .battery
            ? monitor.batteryHistoryIncludingCurrent(at: now)
            : []
        return TimelineSparkGraph(samples: samples,
                           window: window,
                           now: now,
                           tint: MetricChartStyle.chartColor(for: kind),
                           gradient: MetricChartStyle.gradient(for: kind),
                           domain: MetricChartStyle.normalizedDomain,
                           sampleColor: kind == .battery
                               ? { MetricPresentationPolicy.batteryChartColor(level: $0) }
                               : nil,
                           showsLatestEndpoint: kind != .battery || monitor.batteryLevel != nil,
                           gapThreshold: MetricChartStyle.gapThreshold(window: window,
                                                                       maximumPointCount: maximumPointCount),
                           maximumPointCount: maximumPointCount)
    }

    @ViewBuilder private var largeFooter: some View {
        switch kind {
        case .temperature:
            let values = monitor.thermalHistory.map(\.value)
            let low = values.min()
            let high = values.max()
            let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            HStack {
                caption("Low \(tempString(low))", animationValue: low,
                        tint: low.map(Thermal.chartColor) ?? .secondary)
                if size == .large, let average {
                    Spacer()
                    caption("Avg \(tempString(average))", animationValue: average,
                            tint: Thermal.chartColor(average))
                }
                Spacer()
                caption("High \(tempString(high))", animationValue: high,
                        tint: high.map(Thermal.chartColor) ?? .secondary)
            }
        case .cpu:
            HStack { caption("Live Usage"); Spacer(); actionButton("Activity") { state.open(.activity) } }
        case .memory:
            HStack {
                caption("\(Fmt.size(monitor.memoryUsed)) of \(Fmt.size(monitor.memoryTotal))",
                        animationValue: monitor.memoryUsed,
                        tint: chartTint)
                Spacer()
                actionButton("Free Up", busy: freeing) { freeMemory() }
            }
        case .storage:
            HStack {
                if size == .large {
                    caption("\(Fmt.percent(monitor.diskFraction)) Full",
                            animationValue: monitor.diskFraction * 100,
                            tint: chartTint)
                } else {
                    caption("\(Fmt.size(monitor.diskTotal)) Total",
                            animationValue: monitor.diskTotal)
                }
                Spacer()
                actionButton("Open Storage") { state.open(.storage) }
            }
        case .battery:
            HStack {
                caption(batteryCaption, animationValue: batteryCaptionAnimationValue)
                Spacer()
                if let health = monitor.batteryHealth {
                    caption("Health \(Fmt.percent(health))", animationValue: health * 100,
                            tint: Theme.Chart.batteryHealth(health))
                }
            }
        case .network:
            EmptyView()
        }
    }

    // MARK: Network widget

    @ViewBuilder private var networkBody: some View {
        switch size {
        case .small:
            // Small = the network's name and the live rates, stacked so long SSIDs and
            // wide values never fight for one row. The unit toggle lives in medium+.
            VStack(alignment: .leading, spacing: 6) {
                networkHeader
                networkName(size: 15)
                Spacer(minLength: 0)
                if network.online {
                    VStack(alignment: .leading, spacing: 3) {
                        rate("arrow.down", monitor.netDown, Theme.Chart.blue)
                        rate("arrow.up", monitor.netUp, Theme.Chart.mint)
                    }
                } else {
                    networkOfflineState
                }
            }
        case .medium:
            // Medium = small plus the trend: the same dual-series traffic chart the
            // large tile draws, compressed to the unit height, with rates and the
            // speed test on one fixed footer line.
            VStack(alignment: .leading, spacing: 6) {
                networkTitleRows
                if network.online {
                    NetworkTimelineGraph(samples: monitor.networkHistory,
                                         window: SystemMonitor.liveHistoryWindow,
                                         now: Date(),
                                         downTint: Theme.Chart.blue,
                                         upTint: Theme.Chart.mint,
                                         rateUnit: networkRateUnit)
                        .frame(maxHeight: .infinity)
                    HStack(spacing: 8) {
                        rate("arrow.down", monitor.netDown, Theme.Chart.blue)
                        rate("arrow.up", monitor.netUp, Theme.Chart.mint)
                        Spacer(minLength: 6)
                        speedControl
                    }
                    .frame(height: Theme.Layout.compactHitArea)
                } else {
                    networkOfflineState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .large:
            VStack(alignment: .leading, spacing: 8) {
                networkTitleRows
                if network.online {
                    NetworkTrafficChart(samples: monitor.networkHistory,
                                        stats: networkStats,
                                        chartHeight: 104,
                                        rateUnit: networkRateUnit) {
                        VStack(alignment: .trailing, spacing: 4) {
                            if let link = network.linkRateMbps {
                                caption("\(Int(link.rounded())) Mbps Link", animationValue: link)
                            }
                            speedControl
                        }
                        .frame(width: 132, alignment: .trailing)
                    }
                } else {
                    networkOfflineState
                        .frame(maxWidth: .infinity, minHeight: 104)
                }
            }
        }
    }

    private var networkOfflineState: some View {
        Label("Offline", systemImage: "wifi.slash")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    /// Header + name/toggle/security rows shared by the medium and large layouts, so the
    /// widget doesn't jump as it cycles between them.
    @ViewBuilder private var networkTitleRows: some View {
        networkHeader
        HStack(alignment: .firstTextBaseline) {
            networkName(size: 16)
            Spacer()
            networkRateUnitToggle
            securityPill
        }
    }

    private var networkStats: NetworkThroughputStats {
        NetworkThroughputStats(samples: monitor.networkHistory,
                               currentDown: monitor.netDown, currentUp: monitor.netUp)
    }

    private var networkRateUnit: NetworkRateUnit {
        NetworkRateUnit(rawValue: networkRateUnitRawValue) ?? .bytesPerSecond
    }

    private var networkRateUnitIsBits: Binding<Bool> {
        Binding {
            networkRateUnit == .bitsPerSecond
        } set: { isBitsPerSecond in
            withAnimation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion)) {
                networkRateUnitRawValue = isBitsPerSecond
                    ? NetworkRateUnit.bitsPerSecond.rawValue
                    : NetworkRateUnit.bytesPerSecond.rawValue
            }
        }
    }

    private var networkRateUnitToggle: some View {
        Button {
            networkRateUnitIsBits.wrappedValue.toggle()
        } label: {
            NetworkRateUnitSlider(unit: networkRateUnit, isCompact: isSmall)
        }
        .buttonStyle(NetworkRateUnitSliderButtonStyle())
        .help("Show network rates in \(networkRateUnit.toggled.accessibilityLabel)")
        .accessibilityRepresentation {
            Toggle("Network rate unit", isOn: networkRateUnitIsBits)
                .accessibilityValue(networkRateUnit.accessibilityLabel)
                .accessibilityHint("Switch between bytes and bits per second")
        }
    }

    private var networkHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: network.connection.icon).font(.caption)
                .foregroundStyle(network.online ? Theme.accent2 : Theme.warn)
            Text(network.connection.label).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            // Hidden while editing so the glyph never sits under the resize badge.
            if !customizationActive { signalGlyph }
        }
    }

    /// The headline name: the Wi-Fi SSID when macOS will give it to us, otherwise a
    /// state that isn't a redundant "Wi-Fi" — including a tap to reveal a hidden name.
    @ViewBuilder private func networkName(size: CGFloat) -> some View {
        if let ssid = network.ssid, !ssid.isEmpty {
            Text(ssid)
                .font(.rounded(size, .semibold))
                .lineLimit(1).truncationMode(.middle)
        } else if network.connection == .wifi, !network.canShowName {
            Button { network.requestNameAccessAndOpenSettings() } label: {
                Text(network.nameAccess == .denied ? "Open Location" : "Allow Location")
                    .font(.rounded(size, .semibold))
                    .foregroundStyle(Theme.accent2)
            }
            .buttonStyle(.quiet(Theme.accent2, compact: true))
            .help(network.nameAccess == .denied
                  ? "Open Location Services to show the Wi-Fi network name"
                  : "Allow Location so macOS reveals the Wi-Fi network name")
        } else if !network.online {
            Text("Not Connected")
                .font(.rounded(size, .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(network.connection.label)
                .font(.rounded(size, .semibold))
                .lineLimit(1)
        }
    }

    @ViewBuilder private var signalGlyph: some View {
        if network.connection == .wifi, let f = network.signalFraction {
            Image(systemName: "wifi", variableValue: f)
                .font(.caption).foregroundStyle(Theme.status(for: 1 - f))
                .help("Signal \(Int((f * 100).rounded()))%")
        } else if network.connection == .offline {
            Image(systemName: "wifi.slash").font(.caption).foregroundStyle(Theme.warn)
        }
    }

    @ViewBuilder private var securityPill: some View {
        if network.connection == .wifi {
            let strong = network.security.strong
            HStack(spacing: 3) {
                Image(systemName: strong ? "lock.fill" : "lock.open.fill")
                Text(network.security.label)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(strong ? Theme.good : Theme.warn)
        }
    }

    private func rate(_ icon: String, _ value: Double, _ tint: Color) -> some View {
        let animationValue = value.isFinite ? max(0, value) : 0

        return HStack(spacing: NetworkRateStyle.spacing) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: NetworkRateStyle.iconWidth)
            AnimatedNumberText(Fmt.compactRate(value, unit: networkRateUnit),
                               value: networkRateUnit.displayValue(for: animationValue))
                .font(.system(size: NetworkRateStyle.fontSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: NetworkRateStyle.textWidth, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
        .help(Fmt.rate(value, unit: networkRateUnit))
    }

    @ViewBuilder private var speedControl: some View {
        WorkflowPhaseHost(phase: speedPhaseKey) {
            Group {
                if !network.online {
                    Label("Offline", systemImage: "wifi.slash")
                        .foregroundStyle(Theme.warn)
                } else {
                    switch network.speedTest {
                    case .idle:
                        Button { network.runSpeedTest() } label: {
                            Label("Test Speed", systemImage: "gauge.with.dots.needle.67percent")
                        }
                        .buttonStyle(.quiet(Theme.accent, compact: true))
                    case .running(let phase):
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            ContextualSymbol(
                                inactive: "arrow.down",
                                active: "arrow.up",
                                isActive: phase == .upload,
                                tint: phase == .upload ? Theme.accent : Theme.accent2,
                                size: 10
                            )
                            Text(phase == .download ? "Downloading" : "Uploading")
                                .foregroundStyle(.secondary)
                        }
                    case .done(let down, let up):
                        Button { network.runSpeedTest() } label: {
                            HStack(spacing: 5) {
                                AnimatedNumberText("↓\(speedString(down))", value: down)
                                    .foregroundStyle(Theme.Chart.blue)
                                AnimatedNumberText("↑\(speedString(up))", value: up)
                                    .foregroundStyle(Theme.Chart.mint)
                                Text("Mbps").foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.quiet(Theme.accent, compact: true))
                        .help("Run the speed test again")
                    case .failed:
                        Button { network.runSpeedTest() } label: {
                            Label("Retry Test", systemImage: "exclamationmark.arrow.circlepath")
                        }
                        .buttonStyle(.quiet(Theme.accent, compact: true))
                    }
                }
            }
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .frame(width: 132, height: Theme.Layout.compactHitArea, alignment: .trailing)
        }
        .animation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion), value: speedPhaseKey)
    }

    private var speedPhaseKey: String {
        guard network.online else { return "offline" }
        switch network.speedTest {
        case .idle: return "idle"
        case .running(.download): return "download"
        case .running(.upload): return "upload"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    // MARK: Per-metric data

    private var tint: Color {
        switch kind {
        case .temperature:
            return monitor.thermal.available ? Thermal.readoutColor(monitor.thermal.cpu) : .secondary
        case .cpu:         return MetricPresentationPolicy.usageReadoutColor(monitor.cpuUsage)
        case .memory:      return MetricPresentationPolicy.usageReadoutColor(monitor.memoryFraction)
        case .storage:     return MetricPresentationPolicy.usageReadoutColor(monitor.diskFraction)
        case .battery:
            return MetricPresentationPolicy.batteryReadoutColor(level: monitor.batteryLevel)
        case .network:     return network.online ? Theme.accent2 : Theme.warn
        }
    }

    private var chartTint: Color {
        switch kind {
        case .temperature:
            return monitor.thermal.available ? Thermal.chartColor(monitor.thermal.cpu) : .secondary
        case .cpu:
            return Theme.Chart.status(for: monitor.cpuUsage)
        case .memory:
            return Theme.Chart.status(for: monitor.memoryFraction)
        case .storage:
            return Theme.Chart.status(for: monitor.diskFraction)
        case .battery:
            return Theme.Chart.batteryLevel(monitor.batteryLevel)
        case .network:
            return network.online ? Theme.Chart.blue : Theme.Chart.amber
        }
    }

    private var fraction: Double {
        switch kind {
        case .cpu:     return monitor.cpuUsage
        case .memory:  return monitor.memoryFraction
        case .storage: return monitor.diskFraction
        case .battery: return monitor.batteryLevel ?? 1
        default:       return 0
        }
    }

    private var valueText: String {
        switch kind {
        case .temperature: return monitor.thermal.available ? "\(Int(monitor.thermal.cpu.rounded()))°C" : "—"
        case .cpu:         return Fmt.percent(monitor.cpuUsage)
        case .memory:      return Fmt.percent(monitor.memoryFraction)
        case .storage:     return "\(Fmt.size(max(0, monitor.diskTotal - monitor.diskUsed))) Free"
        case .battery:
            if let level = monitor.batteryLevel { return Fmt.percent(level) }
            return monitor.hasBattery ? "—" : "AC"
        case .network:     return network.displayName
        }
    }

    @ViewBuilder private func animatedValueText(size: CGFloat, weight: Font.Weight) -> some View {
        if let animationValue = valueAnimationValue {
            AnimatedNumberText(valueText, value: animationValue)
                .font(.rounded(size, weight))
                .monospacedDigit()
        } else {
            Text(valueText)
                .font(.rounded(size, weight))
                .monospacedDigit()
        }
    }

    private var valueAnimationValue: Double? {
        switch kind {
        case .temperature:
            return monitor.thermal.available ? monitor.thermal.cpu : nil
        case .cpu:
            return monitor.cpuUsage * 100
        case .memory:
            return monitor.memoryFraction * 100
        case .storage:
            return max(0, monitor.diskTotal - monitor.diskUsed)
        case .battery:
            return monitor.batteryLevel.map { $0 * 100 }
        case .network:
            return nil
        }
    }

    private var batteryCaption: String {
        // Desktop / no battery.
        guard monitor.batteryLevel != nil else {
            return monitor.hasBattery ? "Level Unavailable" : "Plugged In"
        }
        // Unplugged — running on the battery.
        guard monitor.batteryOnAC else {
            if let m = monitor.batteryMinutesToEmpty { return "On Battery · \(BatteryInfo.durationString(m)) Left" }
            return "On Battery"
        }
        // Plugged in, but the adapter can't keep up so the battery is still draining.
        if monitor.batteryDraining { return "On Battery · Adapter Can't Keep Up" }
        // Plugged in, on wall power.
        if monitor.batteryFull { return "Plugged In · Fully Charged" }
        if monitor.batteryCharging {
            if let m = monitor.batteryMinutesToFull { return "Plugged In · \(BatteryInfo.durationString(m)) To Full" }
            return "Plugged In · Charging"
        }
        // On wall power, deliberately holding the charge to protect the battery.
        return "Plugged In · Optimized Charging"
    }

    private var batteryCaptionAnimationValue: Double? {
        guard monitor.batteryLevel != nil else { return nil }
        if !monitor.batteryOnAC { return monitor.batteryMinutesToEmpty.map(Double.init) }
        if monitor.batteryCharging, !monitor.batteryFull, !monitor.batteryDraining {
            return monitor.batteryMinutesToFull.map(Double.init)
        }
        return nil
    }

    private func tempString(_ value: Double?) -> String {
        guard let value, monitor.thermal.available else { return "—" }
        return "\(Int(value.rounded()))°"
    }

    private func speedString(_ mbps: Double) -> String {
        mbps >= 100 ? "\(Int(mbps.rounded()))" : String(format: "%.1f", mbps)
    }

    private func freeMemory() {
        guard !freeing else { return }
        freeing = true
        Task {
            _ = await MemoryActions.freeUpRAM()
            monitor.refresh()
            freeing = false
        }
    }
}
