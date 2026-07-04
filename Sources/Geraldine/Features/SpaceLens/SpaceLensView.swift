import SwiftUI

struct SpaceLensView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = SpaceLensViewModel()

    private static let palette: [Color] = [
        Color(red: 0.46, green: 0.40, blue: 0.95), Color(red: 0.36, green: 0.66, blue: 0.98),
        Color(red: 0.30, green: 0.74, blue: 0.74), Color(red: 0.40, green: 0.72, blue: 0.50),
        Color(red: 0.86, green: 0.42, blue: 0.86), Color(red: 0.95, green: 0.55, blue: 0.35),
        Color(red: 0.55, green: 0.60, blue: 0.98), Color(red: 0.98, green: 0.71, blue: 0.27)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .spaceLens) {
                HStack(spacing: 8) {
                    if vm.loading {
                        Button { vm.cancelScan() } label: { Label("Cancel", systemImage: "xmark.circle") }
                    }
                    Button { vm.revealCurrent() } label: { Label("Reveal", systemImage: "arrow.up.forward.app") }
                        .disabled(vm.loading)
                    Button { vm.chooseRoot() } label: { Label("Choose Folder", systemImage: "folder") }
                        .disabled(vm.loading)
                }
            }
            breadcrumb
            SpaceLensScopeBar(freshness: vm.freshnessText,
                              scope: vm.scopeText,
                              visibleCount: vm.visibleNodeCount,
                              totalCount: vm.totalEntryCount,
                              currentSize: vm.currentSize)
            map
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(vm.path.enumerated()), id: \.offset) { index, url in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button { vm.goTo(index) } label: {
                        Text(index == 0 ? url.lastPathComponent.isEmpty ? "Macintosh HD" : url.lastPathComponent
                                        : url.lastPathComponent)
                            .font(.rounded(13, index == vm.path.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == vm.path.count - 1 ? Color.primary : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                Spacer()
                Text(Fmt.size(vm.currentSize)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26).padding(.vertical, 8)
        }
    }

    private var map: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let values = vm.children.map { CGFloat($0.size) }
            let rects = Treemap.layout(values: values, in: rect.insetBy(dx: 0, dy: 0))

            ZStack(alignment: .topLeading) {
                ForEach(Array(vm.children.enumerated()), id: \.element.id) { index, node in
                    if index < rects.count {
                        TreemapCell(node: node,
                                    color: Self.palette[index % Self.palette.count],
                                    rect: rects[index])
                            .onTapGesture { vm.enter(node) }
                            .contextMenu {
                                if node.isAggregate {
                                    Button("Aggregates \(node.aggregateCount) smaller visible items") {}
                                        .disabled(true)
                                } else {
                                    Button("Reveal in Finder") { vm.reveal(node) }
                                    Button(node.isDirectory ? "Open Folder" : "Open") { vm.open(node) }
                                    if node.isDirectory {
                                        Button("Scan Inside") { vm.enter(node) }
                                    }
                                }
                            }
                    }
                }

                if vm.loading {
                    SpaceLensProgressOverlay(text: vm.progressText,
                                             fraction: vm.progressFraction,
                                             cancel: vm.cancelScan)
                }

                if !vm.loading && vm.children.isEmpty {
                    SpaceLensIssueState(issue: vm.issue,
                                        chooseFolder: vm.chooseRoot,
                                        retry: vm.load,
                                        openPermissions: { state.open(.permissions) })
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 4)
    }
}

private struct SpaceLensScopeBar: View {
    var freshness: String
    var scope: String
    var visibleCount: Int
    var totalCount: Int
    var currentSize: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Label(freshness, systemImage: "clock")
                Label("\(visibleCount) Shown of \(totalCount) Entries", systemImage: "square.grid.3x3")
                Spacer()
                Label(Fmt.size(currentSize), systemImage: "internaldrive")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Text(scope)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.035))
    }
}

private struct SpaceLensProgressOverlay: View {
    var text: String
    var fraction: Double?
    var cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.06)
            VStack(spacing: 12) {
                if let fraction {
                    ProgressView(value: fraction)
                        .tint(Module.spaceLens.tint)
                        .frame(width: 220)
                } else {
                    BrandSpinner(tint: Module.spaceLens.tint,
                                 icon: Module.spaceLens.systemImage, size: 56)
                }
                Text(text)
                    .font(.rounded(14, .medium))
                    .foregroundStyle(.secondary)
                Button(action: cancel) {
                    Label("Cancel Scan", systemImage: "xmark.circle")
                }
                .buttonStyle(.soft(Module.spaceLens.tint))
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct SpaceLensIssueState: View {
    var issue: SpaceLensViewModel.ScanIssue
    var chooseFolder: () -> Void
    var retry: () -> Void
    var openPermissions: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            IconBadge(icon: issue.icon, tint: Module.spaceLens.tint, size: 78)
            Text(issue.title.isEmpty ? "Nothing To Show" : issue.title)
                .font(.rounded(18, .semibold))
            Text(issue.message.isEmpty ? "Choose a folder to scan." : issue.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                Button(action: retry) { Label("Try Again", systemImage: "arrow.clockwise") }
                Button(action: chooseFolder) { Label("Choose Folder", systemImage: "folder") }
                if issue == .permissionDenied {
                    Button(action: openPermissions) { Label("Open Permissions", systemImage: "lock.shield") }
                }
            }
            .buttonStyle(.soft(Module.spaceLens.tint))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TreemapCell: View {
    var node: DiskNode
    var color: Color
    var rect: CGRect

    private var showsLabel: Bool { rect.width > 56 && rect.height > 30 }
    private var helpText: String {
        if node.isAggregate {
            return "\(node.name) combines \(node.aggregateCount) smaller visible items - \(Fmt.size(node.size))"
        }
        return "\(node.name) - \(Fmt.size(node.size))"
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color.gradient.opacity(node.isAggregate ? 0.4 : 0.9))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if showsLabel {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            if node.isAggregate {
                                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 9))
                            } else if node.isDirectory {
                                Image(systemName: "folder.fill").font(.system(size: 9))
                            }
                            Text(node.name).font(.rounded(12, .semibold)).lineLimit(1)
                        }
                        Text(Fmt.size(node.size)).font(.system(size: 10)).opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(7)
                }
            }
            .frame(width: max(0, rect.width - 3), height: max(0, rect.height - 3))
            .offset(x: rect.minX, y: rect.minY)
            .help(helpText)
    }
}
