import SwiftUI

struct SpaceLensView: View {
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
                Button { vm.chooseRoot() } label: { Label("Choose folder", systemImage: "folder") }
            }
            breadcrumb
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
                    }
                }
                if vm.loading {
                    ZStack { Color.black.opacity(0.04); ProgressView().controlSize(.large) }
                }
                if !vm.loading && vm.children.isEmpty {
                    EmptyState(icon: "circle.hexagongrid", title: "Nothing to show",
                               message: "This folder is empty or unreadable.", tint: Module.spaceLens.tint)
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 4)
    }
}

private struct TreemapCell: View {
    var node: DiskNode
    var color: Color
    var rect: CGRect

    private var showsLabel: Bool { rect.width > 56 && rect.height > 30 }

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
                            if node.isDirectory && !node.isAggregate {
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
            .help("\(node.name) — \(Fmt.size(node.size))")
    }
}
