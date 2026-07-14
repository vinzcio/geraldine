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

@MainActor
private final class WidgetDragCoordinator: ObservableObject {
    @Published var dragged: WidgetKind?
    @Published var target: WidgetKind?

    func begin(_ kind: WidgetKind) {
        dragged = kind
    }

    func setTarget(_ kind: WidgetKind, active: Bool) {
        if active {
            target = kind
        } else if target == kind {
            target = nil
        }
    }

    func end() {
        dragged = nil
        target = nil
    }
}

private struct WidgetFullWidthKey: LayoutValueKey {
    static let defaultValue = false
}

/// Stable-ID packing without synthetic row identities. Each widget remains the
/// same subview while neighboring tiles reflow between half and full-width rows.
private struct WidgetPackingLayout: Layout {
    var spacing: CGFloat = 8
    private let wideLayoutBreakpoint: CGFloat = 520

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 292
        if width >= wideLayoutBreakpoint {
            return wideSizeThatFits(width: width, subviews: subviews)
        }
        let rows = measuredRows(width: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        if bounds.width >= wideLayoutBreakpoint {
            placeWideSubviews(in: bounds, subviews: subviews)
            return
        }
        let rows = measuredRows(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            for cell in row.cells {
                let x = bounds.minX + (cell.column == 0 ? 0 : cell.width + spacing)
                cell.subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: cell.width, height: row.height)
                )
            }
            y += row.height + spacing
        }
    }

    private struct Cell {
        let subview: LayoutSubview
        let width: CGFloat
        let column: Int
    }

    private struct Row {
        let cells: [Cell]
        let height: CGFloat
    }

    private func wideSizeThatFits(width: CGFloat, subviews: Subviews) -> CGSize {
        let rows = measuredWideRows(width: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height }
            + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    private func placeWideSubviews(in bounds: CGRect, subviews: Subviews) {
        let rows = measuredWideRows(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            for cell in row.cells {
                cell.subview.place(
                    at: CGPoint(x: bounds.minX + cell.x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: cell.width, height: cell.height)
                )
            }
            y += row.height + spacing
        }
    }

    private struct WideCell {
        let subview: LayoutSubview
        let x: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private struct WideRow {
        let cells: [WideCell]
        let height: CGFloat
    }

    /// Four tracks preserve the original small-tile density while letting rich widgets
    /// share a row: small = one track, large/calendar = two tracks.
    private func measuredWideRows(width: CGFloat, subviews: Subviews) -> [WideRow] {
        let trackCount = 4
        let trackWidth = max(0, (width - spacing * CGFloat(trackCount - 1)) / CGFloat(trackCount))
        var rows: [WideRow] = []
        var cells: [WideCell] = []
        var usedTracks = 0

        func appendRow() {
            guard !cells.isEmpty else { return }
            rows.append(WideRow(cells: cells, height: cells.map(\.height).max() ?? 0))
            cells = []
            usedTracks = 0
        }

        for subview in subviews {
            let span = subview[WidgetFullWidthKey.self] ? 2 : 1
            if usedTracks + span > trackCount { appendRow() }
            let cellWidth = trackWidth * CGFloat(span) + spacing * CGFloat(span - 1)
            let height = subview.sizeThatFits(
                ProposedViewSize(width: cellWidth, height: nil)
            ).height
            let x = CGFloat(usedTracks) * (trackWidth + spacing)
            cells.append(WideCell(subview: subview, x: x, width: cellWidth, height: height))
            usedTracks += span
            if usedTracks == trackCount { appendRow() }
        }
        appendRow()
        return rows
    }

    private func measuredRows(width: CGFloat, subviews: Subviews) -> [Row] {
        let halfWidth = max(0, (width - spacing) / 2)
        var rows: [Row] = []
        var index = subviews.startIndex

        while index < subviews.endIndex {
            let first = subviews[index]
            if first[WidgetFullWidthKey.self] {
                let height = first.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                let cell = Cell(subview: first, width: width, column: 0)
                rows.append(Row(cells: [cell], height: height))
                index = subviews.index(after: index)
                continue
            }

            let firstHeight = first.sizeThatFits(ProposedViewSize(width: halfWidth, height: nil)).height
            let firstCell = Cell(subview: first, width: halfWidth, column: 0)
            let next = subviews.index(after: index)
            if next < subviews.endIndex, !subviews[next][WidgetFullWidthKey.self] {
                let second = subviews[next]
                let secondHeight = second.sizeThatFits(ProposedViewSize(width: halfWidth, height: nil)).height
                let secondCell = Cell(subview: second, width: halfWidth, column: 1)
                rows.append(Row(cells: [firstCell, secondCell], height: max(firstHeight, secondHeight)))
                index = subviews.index(after: next)
            } else {
                rows.append(Row(cells: [firstCell], height: firstHeight))
                index = next
            }
        }
        return rows
    }
}

// MARK: - Grid

/// Uses the original iOS-style rows at compact widths. In the wider right-edge panel,
/// four tracks let rich cards share rows while small cards keep their compact density.
struct WidgetGrid: View {
    @EnvironmentObject var layout: WidgetLayoutStore
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var calendar: CalendarSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var customizing = false
    @StateObject private var dragCoordinator = WidgetDragCoordinator()

    var body: some View {
        VStack(spacing: 8) {
            customizationToolbar
            if customizing { customizationPanel }
            widgetRows
        }
        .animation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion), value: visibleItems)
        .environment(\.widgetCustomizationActive, customizing)
        .environmentObject(dragCoordinator)
        .onChange(of: customizing) { _, isCustomizing in
            if !isCustomizing { dragCoordinator.end() }
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
            VStack(spacing: Theme.Spacing.xs) {
                WidgetPackingLayout(spacing: 8) {
                    ForEach(visibleItems) { item in
                        widget(for: item)
                            .frame(maxWidth: .infinity)
                            .layoutValue(key: WidgetFullWidthKey.self, value: isFullWidth(item))
                            .widgetDragAppearance(item.kind)
                    }
                }
                if customizing { WidgetEndDropSlot() }
            }
        }
    }

    private var customizationToolbar: some View {
        HStack(spacing: 6) {
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
                    Text(customizing ? "Done" : "Customize")
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
            .help(customizing ? "Finish customizing widgets" : "Customize menu bar widgets")

            Spacer(minLength: 4)

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

    /// Whether the kind/setting is currently shown in the popover.
    private func isVisible(_ item: WidgetItem) -> Bool {
        guard item.isShown else { return false }
        return isCustomizable(item)
    }

    private func isCustomizable(_ item: WidgetItem) -> Bool {
        switch item.kind {
        case .metric(let metric): return metric.isAvailable(hasBattery: monitor.hasBattery)
        case .keepAwake:          return true
        case .calendar:           return calendar.appearsInPopover
        }
    }

    /// A tile spans the whole row when it's large, or when it can't be shrunk at all.
    private func isFullWidth(_ item: WidgetItem) -> Bool {
        item.size == .large || !item.kind.canResize
    }

    /// Flow the ordered items into rows: a full-width item takes its own row; smalls pair up.
    private var visibleItems: [WidgetItem] {
        layout.items.filter(isVisible)
    }
}

// MARK: - Shared widget chrome

/// Drag-to-reorder handle + size toggle, shared by every widget tile so Keep Awake
/// behaves exactly like the metric widgets.
struct WidgetControls: View {
    @EnvironmentObject var layout: WidgetLayoutStore
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var calendar: CalendarSettingsStore
    @EnvironmentObject private var dragCoordinator: WidgetDragCoordinator
    @Environment(\.widgetCustomizationActive) private var customizationActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: WidgetKind
    let size: WidgetSize

    var body: some View {
        HStack(spacing: 0) {
            if customizationActive {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(Theme.accent.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.accent.opacity(0.30), lineWidth: 1))
                    .frame(width: Theme.Layout.minimumHitArea, height: Theme.Layout.minimumHitArea)
                    .contentShape(Rectangle())
                    .help("Drag to reorder")
                    .draggable(kind.id) {
                        dragPreview
                            .onAppear { dragCoordinator.begin(kind) }
                            .onDisappear { dragCoordinator.end() }
                    }
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Reorder \(kind.title(hasBattery: monitor.hasBattery))")
                    .accessibilityHint("Drag, or use Move Earlier and Move Later actions.")
                    .accessibilityAction(named: Text("Move Earlier")) {
                        withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
                            moveEarlier()
                        }
                    }
                    .accessibilityAction(named: Text("Move Later")) {
                        withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
                            moveLater()
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: GeraldineMotion.iconSwapScale)))
            }

            if kind.canResize {
                Button {
                    withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
                        layout.toggleSize(kind)
                    }
                } label: {
                    ContextualSymbol(
                        inactive: "arrow.up.left.and.arrow.down.right",
                        active: "arrow.down.right.and.arrow.up.left",
                        isActive: size == .large,
                        tint: customizationActive ? Theme.accent : Color(nsColor: .secondaryLabelColor),
                        size: 10
                    )
                }
                .buttonStyle(.quiet(customizationActive ? Theme.accent : Color.secondary))
                .minimumHitArea()
                .help(size == .small ? "Expand widget" : "Shrink widget")
                .accessibilityLabel(size == .small
                                    ? "Expand \(kind.title(hasBattery: monitor.hasBattery))"
                                    : "Shrink \(kind.title(hasBattery: monitor.hasBattery))")
            }
        }
        .animation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion), value: customizationActive)
    }

    @ViewBuilder private var dragPreview: some View {
        HStack(spacing: 5) {
            switch kind {
            case .metric(let metric): Image(systemName: metric.icon(hasBattery: monitor.hasBattery))
            case .keepAwake:          EyeView(isActive: false, size: 16)
            case .calendar:           Image(systemName: "calendar")
            }
            Text(kind.title(hasBattery: monitor.hasBattery))
        }
        .font(.caption).padding(6)
        .adaptiveMaterialBackground(.ultraThin, in: Capsule())
    }

    private var visibleOrder: [WidgetKind] {
        layout.items.compactMap { item in
            guard item.isShown else { return nil }
            switch item.kind {
            case .metric(let metric):
                return metric.isAvailable(hasBattery: monitor.hasBattery) ? item.kind : nil
            case .keepAwake:
                return item.kind
            case .calendar:
                return calendar.appearsInPopover ? item.kind : nil
            }
        }
    }

    private func moveEarlier() {
        guard let index = visibleOrder.firstIndex(of: kind), index > 0 else { return }
        layout.move(kind, before: visibleOrder[index - 1])
    }

    private func moveLater() {
        guard let index = visibleOrder.firstIndex(of: kind), index + 1 < visibleOrder.count else { return }
        layout.move(visibleOrder[index + 1], before: kind)
    }
}

/// Accept a dropped widget id and reorder it before `target`.
private struct WidgetDropTarget: ViewModifier {
    @EnvironmentObject var layout: WidgetLayoutStore
    @EnvironmentObject private var dragCoordinator: WidgetDragCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.widgetCustomizationActive) private var customizationActive
    let target: WidgetKind

    func body(content: Content) -> some View {
        content
            .dropDestination(for: String.self) { dropped, _ in
                guard customizationActive else { return false }
                guard let raw = dropped.first,
                      let dragged = WidgetKind(id: raw),
                      dragged != target else {
                    dragCoordinator.end()
                    return false
                }
                withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
                    layout.move(dragged, before: target)
                }
                dragCoordinator.end()
                return true
            } isTargeted: { isTargeted in
                dragCoordinator.setTarget(target, active: isTargeted && customizationActive)
            }
    }
}

private struct WidgetEndDropSlot: View {
    @EnvironmentObject private var layout: WidgetLayoutStore
    @EnvironmentObject private var dragCoordinator: WidgetDragCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Capsule()
                .fill(isTargeted ? Theme.accent : Theme.separator)
                .frame(height: isTargeted ? 4 : 2)
                .shadow(color: isTargeted ? Theme.accent.opacity(0.48) : .clear,
                        radius: isTargeted ? 7 : 0)
            if dragCoordinator.dragged != nil {
                Text("Drop At End")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isTargeted ? Theme.accent : .secondary)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Layout.minimumHitArea)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { dropped, _ in
            guard let raw = dropped.first, let kind = WidgetKind(id: raw) else {
                dragCoordinator.end()
                return false
            }
            withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
                layout.moveToEnd(kind)
            }
            dragCoordinator.end()
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .accessibilityHidden(dragCoordinator.dragged == nil)
    }
}

private struct WidgetDragAppearance: ViewModifier {
    @EnvironmentObject private var dragCoordinator: WidgetDragCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: WidgetKind

    func body(content: Content) -> some View {
        let isDragged = dragCoordinator.dragged == kind
        let isTarget = dragCoordinator.target == kind && !isDragged
        content
            .scaleEffect(isDragged && !reduceMotion ? 1.018 : 1)
            .offset(y: isDragged && !reduceMotion ? -3 : 0)
            .opacity(isDragged ? 0.88 : 1)
            .padding(.leading, isTarget && !reduceMotion ? 8 : 0)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(isTarget ? Theme.accent.opacity(0.28) : .clear, lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(isTarget ? Theme.accent : .clear)
                    .frame(width: 4)
                    .padding(.vertical, Theme.Spacing.xs)
                    .offset(x: isTarget ? -2 : 0)
                    .shadow(color: isTarget ? Theme.accent.opacity(0.55) : .clear,
                            radius: isTarget ? 7 : 0)
            }
            .zIndex(isDragged ? 2 : (isTarget ? 1 : 0))
            .animation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion),
                       value: dragCoordinator.dragged)
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion),
                       value: dragCoordinator.target)
    }
}

extension View {
    func widgetDropTarget(_ target: WidgetKind) -> some View {
        modifier(WidgetDropTarget(target: target))
    }

    fileprivate func widgetDragAppearance(_ kind: WidgetKind) -> some View {
        modifier(WidgetDragAppearance(kind: kind))
    }
}

// MARK: - Widget

/// One resizable, draggable metric tile. Small = compact readout; large = adds a chart.
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
    private var networkRateFontSize: CGFloat { isSmall ? 11 : 12 }
    private var networkRateIconWidth: CGFloat { isSmall ? 8 : 10 }
    private var networkRateSpacing: CGFloat { isSmall ? 2 : 5 }
    private var networkRateTextWidth: CGFloat { isSmall ? 48 : 56 }

    var body: some View {
        Group {
            if kind == .network { networkBody } else { standardBody }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: isSmall ? 120 : nil, alignment: .topLeading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(customizationActive ? Theme.accent.opacity(0.24) : .clear, lineWidth: 1))
        .widgetDropTarget(.metric(kind))
    }

    // MARK: Shared chrome

    private var controls: some View { WidgetControls(kind: .metric(kind), size: size) }

    private func headerRow(@ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 5) {
            Image(systemName: kind.icon(hasBattery: monitor.hasBattery)).font(.caption).foregroundStyle(tint)
            Text(kind.title(hasBattery: monitor.hasBattery)).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
            controls
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
        .buttonStyle(.quiet(Theme.accent)).disabled(busy)
    }

    @ViewBuilder private func caption(_ text: String, animationValue: Double? = nil) -> some View {
        if let animationValue {
            AnimatedNumberText(text, value: animationValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Standard metrics (temperature / cpu / memory / storage / battery)

    @ViewBuilder private var standardBody: some View {
        VStack(alignment: .leading, spacing: isSmall ? 6 : 8) {
            headerRow {
                if !isSmall {
                    animatedValueText(size: 15, weight: .semibold)
                        .foregroundStyle(kind == .temperature ? tint : .primary)
                }
            }
            if isSmall { standardSmall } else { standardLarge }
        }
    }

    @ViewBuilder private var standardSmall: some View {
        animatedValueText(size: 16, weight: .semibold)
            .foregroundStyle(kind == .temperature ? tint : .primary)
        if kind == .battery {
            normalizedHistoryChart(window: MetricChartStyle.smallWindow,
                                   maximumPointCount: MetricChartStyle.smallMaxPoints)
                .frame(height: 28)
        } else if kind == .storage {
            StatBar(fraction: fraction, tint: chartTint, height: 6)
        } else if kind != .temperature {
            StatBar(fraction: fraction, tint: chartTint, height: 5)
        }
        Spacer(minLength: 0)
        smallFooter
    }

    @ViewBuilder private var smallFooter: some View {
        switch kind {
        case .temperature: caption(monitor.thermal.available ? "CPU Die" : "Unavailable")
        case .cpu:         actionButton("Details") { state.open(.activity) }
        case .memory:      actionButton("Free Up", busy: freeing) { freeMemory() }
        case .storage:
            HStack {
                caption("\(Fmt.percent(monitor.diskFraction)) Used",
                        animationValue: monitor.diskFraction * 100)
                Spacer(minLength: 4)
                actionButton("Review") { state.open(.storage) }
            }
        case .battery:     caption(batteryCaption, animationValue: batteryCaptionAnimationValue)
        case .network:     EmptyView()
        }
    }

    @ViewBuilder private var standardLarge: some View {
        if kind == .storage {
            storageCapacitySummary
                .frame(height: 66)
        } else {
            chart.frame(height: 66)
        }
        largeFooter
    }

    private var storageCapacitySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatBar(fraction: monitor.diskFraction, tint: chartTint, height: 8)
            HStack(spacing: 16) {
                caption("\(Fmt.size(monitor.diskUsed)) Used", animationValue: monitor.diskUsed)
                Spacer(minLength: 4)
                caption("\(Fmt.percent(monitor.diskFraction)) Full",
                        animationValue: monitor.diskFraction * 100)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var chart: some View {
        switch kind {
        case .temperature:
            liveHistoryChart(samples: monitor.thermalHistory,
                             tint: MetricChartStyle.chartColor(for: .temperature),
                             gradientColors: Thermal.scaleColors,
                             domain: Thermal.chartDomain,
                             valueColor: Thermal.chartColor)
        case .cpu:
            liveHistoryChart(samples: monitor.cpuHistory,
                             tint: MetricChartStyle.chartColor(for: .cpu),
                             gradientColors: MetricChartStyle.gradient(for: .cpu),
                             domain: MetricChartStyle.normalizedDomain)
        case .memory:
            liveHistoryChart(samples: monitor.memHistory,
                             tint: MetricChartStyle.chartColor(for: .memory),
                             gradientColors: MetricChartStyle.gradient(for: .memory),
                             domain: MetricChartStyle.normalizedDomain)
        case .battery:
            normalizedHistoryChart(window: MetricChartStyle.expandedWindow,
                                   maximumPointCount: MetricChartStyle.expandedMaxPoints)
        case .storage:
            EmptyView()
        case .network:
            EmptyView()
        }
    }

    private var slowMetricHistory: [MetricSample] {
        switch kind {
        case .battery:
            return monitor.batteryHistory
        default:
            return []
        }
    }

    private func liveHistoryChart(samples: [MetricSample], tint: Color,
                                  gradientColors: [Color]?, domain: ClosedRange<Double>,
                                  valueColor: ((Double) -> Color)? = nil) -> some View {
        TimelineSparkGraph(samples: samples,
                           window: SystemMonitor.liveHistoryWindow,
                           now: Date(),
                           tint: tint,
                           gradientColors: gradientColors,
                           domain: domain,
                           valueColor: valueColor,
                           gapThreshold: SystemMonitor.chartSampleGapThreshold,
                           maximumPointCount: 300)
    }

    private func normalizedHistoryChart(window: TimeInterval, maximumPointCount: Int) -> some View {
        TimelineSparkGraph(samples: slowMetricHistory,
                           window: window,
                           now: Date(),
                           tint: MetricChartStyle.chartColor(for: kind),
                           gradientColors: MetricChartStyle.gradient(for: kind),
                           domain: MetricChartStyle.normalizedDomain,
                           gapThreshold: MetricChartStyle.gapThreshold(window: window,
                                                                       maximumPointCount: maximumPointCount),
                           maximumPointCount: maximumPointCount)
    }

    @ViewBuilder private var largeFooter: some View {
        switch kind {
        case .temperature:
            let low = monitor.thermalHistory.map(\.value).min()
            let high = monitor.thermalHistory.map(\.value).max()
            HStack {
                caption("Low \(tempString(low))", animationValue: low)
                Spacer()
                caption("High \(tempString(high))", animationValue: high)
            }
        case .cpu:
            HStack { caption("Live Usage"); Spacer(); actionButton("Activity") { state.open(.activity) } }
        case .memory:
            HStack {
                caption("\(Fmt.size(monitor.memoryUsed)) of \(Fmt.size(monitor.memoryTotal))",
                        animationValue: monitor.memoryUsed)
                Spacer()
                actionButton("Free Up", busy: freeing) { freeMemory() }
            }
        case .storage:
            HStack {
                caption("\(Fmt.size(monitor.diskTotal)) Total",
                        animationValue: monitor.diskTotal)
                Spacer()
                actionButton("Open Storage") { state.open(.storage) }
            }
        case .battery:
            HStack {
                caption(batteryCaption, animationValue: batteryCaptionAnimationValue)
                Spacer()
                if let health = monitor.batteryHealth {
                    caption("Health \(Fmt.percent(health))", animationValue: health * 100)
                }
            }
        case .network:
            EmptyView()
        }
    }

    // MARK: Network widget

    @ViewBuilder private var networkBody: some View {
        if isSmall {
            VStack(alignment: .leading, spacing: 6) {
                networkHeader
                HStack(spacing: 5) {
                    networkName(size: 14)
                    Spacer(minLength: 4)
                    networkRateUnitToggle
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    rate("arrow.down", monitor.netDown, Theme.accent2)
                    rate("arrow.up", monitor.netUp, Theme.accent)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                networkHeader
                HStack(alignment: .firstTextBaseline) {
                    networkName(size: 16)
                    Spacer()
                    networkRateUnitToggle
                    securityPill
                }
                NetworkTrafficChart(samples: monitor.networkHistory,
                                    stats: networkStats,
                                    rateUnit: networkRateUnit)
                HStack(spacing: 8) {
                    if let link = network.linkRateMbps {
                        caption("\(Int(link.rounded())) Mbps Link", animationValue: link)
                    }
                    Spacer(minLength: 6)
                    speedControl
                }
            }
        }
    }

    private var networkStats: NetworkThroughputStats {
        NetworkThroughputStats(samples: monitor.networkHistory,
                               currentDown: monitor.netDown, currentUp: monitor.netUp)
    }

    private var networkRateUnit: NetworkRateUnit {
        NetworkRateUnit(rawValue: networkRateUnitRawValue) ?? .bytesPerSecond
    }

    private var networkRateUnitToggle: some View {
        Button {
            withAnimation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion)) {
                networkRateUnitRawValue = networkRateUnit.toggled.rawValue
            }
        } label: {
            Text(networkRateUnit.compactLabel)
                .font(.system(size: 9.5, weight: .semibold).monospaced())
                .frame(minWidth: 22)
        }
        .buttonStyle(.quiet(Theme.accent2))
        .help("Switch to \(networkRateUnit.toggled.accessibilityLabel)")
        .accessibilityLabel("Network rate unit")
        .accessibilityValue(networkRateUnit.accessibilityLabel)
        .accessibilityHint("Switch to \(networkRateUnit.toggled.accessibilityLabel)")
    }

    private var networkHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: network.connection.icon).font(.caption)
                .foregroundStyle(network.online ? Theme.accent2 : Theme.warn)
            Text(network.connection.label).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            signalGlyph
            controls
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
            .buttonStyle(.quiet(Theme.accent2))
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

        return HStack(spacing: networkRateSpacing) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: networkRateIconWidth)
            AnimatedNumberText(Fmt.compactRate(value, unit: networkRateUnit),
                               value: networkRateUnit.displayValue(for: animationValue))
                .font(.system(size: networkRateFontSize, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(isSmall ? 0.82 : 0.9)
                .frame(width: networkRateTextWidth, alignment: .leading)
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
                        .buttonStyle(.quiet(Theme.accent))
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
                            Text(phase == .download ? "Testing Download" : "Testing Upload")
                                .foregroundStyle(.secondary)
                        }
                    case .done(let down, let up):
                        Button { network.runSpeedTest() } label: {
                            HStack(spacing: 5) {
                                AnimatedNumberText("↓\(speedString(down))", value: down)
                                    .foregroundStyle(Theme.accent2)
                                AnimatedNumberText("↑\(speedString(up))", value: up)
                                    .foregroundStyle(Theme.accent)
                                Text("Mbps").foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.quiet(Theme.accent))
                        .help("Run the speed test again")
                    case .failed:
                        Button { network.runSpeedTest() } label: {
                            Label("Retry Test", systemImage: "exclamationmark.arrow.circlepath")
                        }
                        .buttonStyle(.quiet(Theme.accent))
                    }
                }
            }
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .frame(width: 162, height: Theme.Layout.minimumHitArea, alignment: .trailing)
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
        case .temperature: return Thermal.color(monitor.thermal.cpu)
        case .cpu:         return Theme.status(for: monitor.cpuUsage)
        case .memory:      return Theme.status(for: monitor.memoryFraction)
        case .storage:     return Theme.status(for: monitor.diskFraction)
        case .battery:     return (monitor.batteryLevel ?? 1) < 0.2 ? Theme.bad : Theme.good
        case .network:     return network.online ? Theme.accent2 : Theme.warn
        }
    }

    private var chartTint: Color {
        switch kind {
        case .temperature:
            return Thermal.chartColor(monitor.thermal.cpu)
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
        case .battery:     return monitor.batteryLevel.map(Fmt.percent) ?? "AC"
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
        guard monitor.batteryLevel != nil else { return "Plugged In" }
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
