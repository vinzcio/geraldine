import SwiftUI

struct SpaceLensView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var vm = SpaceLensViewModel()
    @State private var zoomAnchor = UnitPoint.center
    @State private var anchorsByDirectory: [String: UnitPoint] = [:]

    private static let palette: [Color] = [
        Theme.accent, Theme.accent2, Theme.aqua, Theme.green,
        Theme.plum, Theme.orange, Theme.indigo, Theme.warn
    ]

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .spaceLens) {
                HStack(spacing: Theme.Spacing.xs) {
                    if vm.canGoBack {
                        Button { navigateBack() } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .buttonStyle(.quiet(Module.spaceLens.tint))
                        .keyboardShortcut("[", modifiers: .command)
                    }

                    if vm.loading {
                        Button { vm.cancelScan() } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.geraldineDestructive)
                    }

                    Button { vm.revealCurrent() } label: {
                        Label("Reveal", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.quiet(Module.spaceLens.tint))
                    .disabled(vm.loading)

                    Button {
                        zoomAnchor = .center
                        vm.chooseRoot()
                    } label: {
                        Label("Choose Folder", systemImage: "folder")
                    }
                    .buttonStyle(.soft(Module.spaceLens.tint))
                    .disabled(vm.loading)
                }
            }

            breadcrumb

            SpaceLensScopeBar(
                freshness: vm.freshnessText,
                scope: vm.scopeText,
                visibleCount: vm.visibleNodeCount,
                totalCount: vm.totalEntryCount,
                currentSize: vm.currentSize
            )

            map
        }
    }

    private var breadcrumbItems: [SpaceLensBreadcrumb] {
        vm.path.enumerated().map { SpaceLensBreadcrumb(index: $0.offset, url: $0.element) }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xxs) {
                ForEach(breadcrumbItems) { item in
                    if item.index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }

                    if item.index == vm.path.count - 1 {
                        Label(item.displayName, systemImage: "folder.fill")
                            .font(.rounded(13, .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, Theme.Spacing.xs)
                            .frame(minHeight: Theme.Layout.minimumHitArea)
                            .accessibilityAddTraits(.isSelected)
                    } else {
                        Button { navigate(to: item.index) } label: {
                            Text(item.displayName)
                                .lineLimit(1)
                        }
                        .buttonStyle(.quiet(Module.spaceLens.tint))
                        .accessibilityHint("Returns to this folder's disk map")
                    }
                }

                Spacer(minLength: Theme.Spacing.md)

                Label(Fmt.size(vm.currentSize), systemImage: "rectangle.3.group.fill")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("Size represented by the visible map")
            }
            .padding(.horizontal, Theme.Layout.pagePadding)
            .padding(.vertical, Theme.Spacing.xxs)
        }
    }

    private var map: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let canvas = bounds.insetBy(dx: Theme.Spacing.xs, dy: Theme.Spacing.xs)
            let values = vm.children.map { CGFloat($0.size) }
            let rects = Treemap.layout(values: values, in: canvas)
            let total = max(1, vm.currentSize)

            ZStack(alignment: .topLeading) {
                if !vm.children.isEmpty {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(vm.children.enumerated()), id: \.element.id) { index, node in
                            if index < rects.count {
                                let cellRect = rects[index]
                                TreemapCell(
                                    node: node,
                                    color: Self.palette[node.paletteIndex],
                                    rect: cellRect,
                                    share: Double(node.size) / Double(total),
                                    action: {
                                        activate(node, from: cellRect, in: canvas)
                                    },
                                    reveal: {
                                        node.isAggregate ? vm.revealCurrent() : vm.reveal(node)
                                    }
                                )
                                .accessibilitySortPriority(Double(vm.children.count - index))
                                .contextMenu {
                                    if node.isAggregate {
                                        Button("Aggregates \(node.aggregateCount) Smaller Visible Items") {}
                                            .disabled(true)
                                        Button("Reveal Current Folder") { vm.revealCurrent() }
                                    } else {
                                        Button("Reveal in Finder") { vm.reveal(node) }
                                        Button(node.isDirectory ? "Open Folder" : "Open") { vm.open(node) }
                                        if node.isDirectory {
                                            Button("Scan Inside") {
                                                activate(node, from: cellRect, in: canvas)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .id(vm.snapshotDirectory?.standardizedFileURL.path ?? "space-lens-initial-map")
                    .transition(mapTransition)
                }

                if vm.loading {
                    SpaceLensProgressOverlay(
                        text: vm.progressText,
                        fraction: vm.progressFraction,
                        hasSnapshot: !vm.children.isEmpty,
                        cancel: vm.cancelScan
                    )
                    .transition(GeraldineMotion.stateTransition(reduceMotion: reduceMotion))
                    .zIndex(100)
                }

                if !vm.loading && vm.children.isEmpty {
                    SpaceLensIssueState(
                        issue: vm.issue,
                        chooseFolder: {
                            zoomAnchor = .center
                            vm.chooseRoot()
                        },
                        retry: vm.load,
                        openPermissions: { state.open(.permissions) }
                    )
                    .transition(GeraldineMotion.stateTransition(reduceMotion: reduceMotion))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(Theme.surfaceBase)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.raised, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.raised, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            }
            .animation(
                GeraldineMotion.animation(.emphasis, reduceMotion: reduceMotion),
                value: vm.snapshotRevision
            )
            .animation(
                GeraldineMotion.animation(.standard, reduceMotion: reduceMotion),
                value: vm.loading
            )
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.xxs)
        .padding(.bottom, Theme.Spacing.lg)
    }

    private var mapTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }

        let expandFromSelection = AnyTransition.opacity.combined(
            with: .scale(scale: 0.78, anchor: zoomAnchor)
        )
        let movePastSelection = AnyTransition.opacity.combined(
            with: .scale(scale: 1.035, anchor: zoomAnchor)
        )

        switch vm.navigationDirection {
        case let direction where direction > 0:
            return .asymmetric(insertion: expandFromSelection, removal: movePastSelection)
        case let direction where direction < 0:
            return .asymmetric(insertion: movePastSelection, removal: expandFromSelection)
        default:
            return GeraldineMotion.stateTransition(reduceMotion: false)
        }
    }

    private func activate(_ node: DiskNode, from rect: CGRect, in bounds: CGRect) {
        if node.isDirectory, !node.isAggregate {
            let anchor = unitPoint(for: rect, in: bounds)
            zoomAnchor = anchor
            anchorsByDirectory[node.id] = anchor
        }
        vm.activate(node)
    }

    private func navigateBack() {
        zoomAnchor = anchorsByDirectory[vm.current.standardizedFileURL.path] ?? .center
        vm.goBack()
    }

    private func navigate(to index: Int) {
        zoomAnchor = anchorsByDirectory[vm.current.standardizedFileURL.path] ?? .center
        vm.goTo(index)
    }

    private func unitPoint(for rect: CGRect, in bounds: CGRect) -> UnitPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .center }
        return UnitPoint(
            x: min(1, max(0, (rect.midX - bounds.minX) / bounds.width)),
            y: min(1, max(0, (rect.midY - bounds.minY) / bounds.height))
        )
    }
}

private struct SpaceLensBreadcrumb: Identifiable {
    let index: Int
    let url: URL

    var id: String { url.standardizedFileURL.path }
    var displayName: String {
        if url.path == "/" { return "Macintosh HD" }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}

private struct SpaceLensScopeBar: View {
    var freshness: String
    var scope: String
    var visibleCount: Int
    var totalCount: Int
    var currentSize: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.md) {
                Label(freshness, systemImage: "clock")
                Label("\(visibleCount) Shown of \(totalCount) Entries", systemImage: "square.grid.3x3")
                Spacer()
                Label(Fmt.size(currentSize), systemImage: "internaldrive")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Text(scope)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Layout.pagePadding)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.surfaceMuted.opacity(0.58))
        .accessibilityElement(children: .contain)
    }
}

private struct SpaceLensProgressOverlay: View {
    var text: String
    var fraction: Double?
    var hasSnapshot: Bool
    var cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(hasSnapshot ? 0.14 : 0.05)

            VStack(spacing: Theme.Spacing.sm) {
                if let fraction {
                    ProgressView(value: fraction)
                        .tint(Module.spaceLens.tint)
                        .frame(width: 240)
                } else {
                    BrandSpinner(
                        tint: Module.spaceLens.tint,
                        icon: Module.spaceLens.systemImage,
                        size: 58
                    )
                }

                Text(text)
                    .font(.geraldineSection)
                    .foregroundStyle(.secondary)

                if hasSnapshot {
                    Text("Keeping your previous map in place while this folder is measured.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }

                Button(action: cancel) {
                    Label("Cancel Scan", systemImage: "xmark.circle")
                }
                .buttonStyle(.geraldineDestructive)
            }
            .padding(Theme.Spacing.xl)
            .card(tier: .floating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space Lens scan in progress")
        .accessibilityValue(text)
    }
}

private struct SpaceLensIssueState: View {
    var issue: SpaceLensViewModel.ScanIssue
    var chooseFolder: () -> Void
    var retry: () -> Void
    var openPermissions: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            IconBadge(icon: issue.icon, tint: Module.spaceLens.tint, size: 78)
            Text(issue.title.isEmpty ? "Nothing To Show" : issue.title)
                .font(.geraldineTitle)
            Text(issue.message.isEmpty ? "Choose a folder to scan." : issue.message)
                .font(.geraldineBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: Theme.Spacing.xs) {
                Button(action: retry) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.soft(Module.spaceLens.tint))

                Button(action: chooseFolder) {
                    Label("Choose Folder", systemImage: "folder")
                }
                .buttonStyle(BrandProminentButtonStyle())

                if issue == .permissionDenied {
                    Button(action: openPermissions) {
                        Label("Open Permissions", systemImage: "lock.shield")
                    }
                    .buttonStyle(.quiet(Module.spaceLens.tint))
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TreemapCell: View {
    private enum LabelLevel: Equatable {
        case none
        case symbol
        case title
        case value
        case detail
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var node: DiskNode
    var color: Color
    var rect: CGRect
    var share: Double
    var action: () -> Void
    var reveal: () -> Void

    private var cellWidth: CGFloat { max(1, rect.width - 4) }
    private var cellHeight: CGFloat { max(1, rect.height - 4) }
    private var isElevated: Bool { isHovered || isFocused }

    private var labelLevel: LabelLevel {
        switch (cellWidth, cellHeight) {
        case let (width, height) where width >= 150 && height >= 76: return .detail
        case let (width, height) where width >= 82 && height >= 48: return .value
        case let (width, height) where width >= 54 && height >= 30: return .title
        case let (width, height) where width >= 24 && height >= 22: return .symbol
        default: return .none
        }
    }

    private var symbol: String {
        if node.isAggregate { return "square.stack.3d.up.fill" }
        return node.isDirectory ? "folder.fill" : "doc.fill"
    }

    private var helpText: String {
        if node.isAggregate {
            return "\(node.name) combines \(node.aggregateCount) smaller visible items — \(Fmt.size(node.size))"
        }
        return "\(node.name) — \(Fmt.size(node.size))"
    }

    private var accessibilityHint: String {
        if node.isAggregate {
            return "Reveals the current folder containing these smaller items in Finder."
        }
        if node.isDirectory {
            return "Scans inside this folder. The context menu can reveal it in Finder."
        }
        return "Opens this item. The context menu can reveal it in Finder."
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)

        Button(action: action) {
            ZStack(alignment: .topLeading) {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(node.isAggregate ? 0.62 : 0.96),
                                color.opacity(node.isAggregate ? 0.42 : 0.74)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if labelLevel != .none {
                    shape.fill(
                        LinearGradient(
                            colors: [.black.opacity(0.24), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }

                cellLabel
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
            }
            .overlay {
                shape.strokeBorder(
                    isFocused
                        ? Theme.focusRing
                        : Color.white.opacity(isHovered ? 0.48 : (colorScheme == .dark ? 0.24 : 0.34)),
                    lineWidth: isFocused ? 2.5 : (isHovered ? 1.5 : 1)
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .frame(width: cellWidth, height: cellHeight)
        .offset(x: rect.minX + 2, y: rect.minY + 2)
        .focusable()
        .focused($isFocused)
        .scaleEffect(isElevated && !reduceMotion ? 1.012 : 1)
        .shadow(
            color: .black.opacity(isElevated ? 0.30 : 0.10),
            radius: isElevated ? 12 : 2,
            y: isElevated ? 5 : 1
        )
        .zIndex(isElevated ? 10 : 0)
        .onHover { isHovered = $0 }
        .animation(
            GeraldineMotion.animation(.quick, reduceMotion: reduceMotion),
            value: isHovered
        )
        .animation(
            GeraldineMotion.animation(.quick, reduceMotion: reduceMotion),
            value: isFocused
        )
        .pointingHandCursor()
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.name)
        .accessibilityValue(
            "\(Fmt.size(node.size)), \(Int((share * 100).rounded())) percent of visible map, \(node.isDirectory ? "folder" : node.isAggregate ? "grouped items" : "file")"
        )
        .accessibilityHint(accessibilityHint)
        .accessibilityAction(named: Text(node.isAggregate ? "Reveal Current Folder" : "Reveal in Finder")) {
            reveal()
        }
    }

    @ViewBuilder
    private var cellLabel: some View {
        switch labelLevel {
        case .none:
            EmptyView()

        case .symbol:
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .padding(6)

        case .title:
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(node.name)
                    .font(.rounded(11, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .padding(7)

        case .value:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xxs) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                    Text(node.name)
                        .font(.rounded(12, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                Text(Fmt.size(node.size))
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .opacity(0.88)
            }
            .padding(8)

        case .detail:
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xxs) {
                    Image(systemName: symbol)
                    Text(node.name)
                        .lineLimit(1)
                }
                .font(.rounded(13, .semibold))

                Text(Fmt.size(node.size))
                    .font(.rounded(11, .semibold).monospacedDigit())

                Text("\(Int((share * 100).rounded()))% of this map")
                    .font(.caption2.weight(.medium))
                    .opacity(0.76)
            }
            .padding(10)
        }
    }
}
