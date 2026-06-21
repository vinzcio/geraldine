import SwiftUI

@MainActor
final class StorageViewModel: ObservableObject {
    @Published var loading = false
    @Published var segments: [DonutSegment] = []
    @Published var freeText = "—"
    @Published var totalText = ""

    func load() {
        loading = true
        Task {
            let r = await Self.compute()
            self.segments = r.segments
            self.freeText = r.freeText
            self.totalText = r.totalText
            self.loading = false
        }
    }

    private struct Result { var segments: [DonutSegment]; var freeText: String; var totalText: String }

    private static func compute() async -> Result {
        await Task.detached(priority: .userInitiated) { () -> Result in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let root = URL(fileURLWithPath: "/")
            let v = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                       .volumeAvailableCapacityForImportantUsageKey])
            let total = Double(v?.volumeTotalCapacity ?? 0)
            let free = Double(v?.volumeAvailableCapacityForImportantUsage ?? 0)

            let apps = Double(DiskScan.size(of: URL(fileURLWithPath: "/Applications")))
            let docs = Double(DiskScan.size(of: home.appendingPathComponent("Documents")))
            let desk = Double(DiskScan.size(of: home.appendingPathComponent("Desktop")))
            let dl = Double(DiskScan.size(of: home.appendingPathComponent("Downloads")))
            let used = max(0, total - free)
            let other = max(0, used - (apps + docs + desk + dl))

            let raw: [(String, Double, Color)] = [
                ("Applications", apps, Theme.accent),
                ("Documents", docs, Theme.accent2),
                ("Desktop", desk, Color(red: 0.30, green: 0.74, blue: 0.74)),
                ("Downloads", dl, Color(red: 0.95, green: 0.55, blue: 0.35)),
                ("System & Other", other, Color(white: 0.55)),
                ("Available", free, Color(white: 0.82))
            ]
            let segments = raw.filter { $0.1 > 0 }.map { DonutSegment(label: $0.0, value: $0.1, color: $0.2) }
            return Result(segments: segments, freeText: Fmt.size(free),
                          totalText: "free of \(Fmt.size(total))")
        }.value
    }
}

struct StorageView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = StorageViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .storage) {
                Button { vm.load() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }

            if vm.loading && vm.segments.isEmpty {
                ScanningState(tint: Module.storage.tint, label: "Measuring your disk…")
            } else {
                ScrollView {
                    VStack(spacing: 22) {
                        HStack(spacing: 32) {
                            DonutChart(segments: vm.segments, centerTitle: vm.freeText,
                                       centerSubtitle: vm.totalText, lineWidth: 30)
                                .frame(width: 220, height: 220)
                                .opacity(vm.loading ? 0.5 : 1)

                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(vm.segments) { seg in
                                    HStack(spacing: 10) {
                                        Circle().fill(seg.color).frame(width: 11, height: 11)
                                        Text(seg.label).font(.callout)
                                        Spacer()
                                        Text(Fmt.size(seg.value)).font(.callout.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: 280)
                        }
                        .card(padding: 24)

                        Button { state.open(.cleanup) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles").foregroundStyle(Module.cleanup.tint)
                                Text("Free up space with Cleanup").font(.rounded(14, .medium))
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .card(padding: 14)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(26)
                }
            }
        }
        .onAppear { if vm.segments.isEmpty { vm.load() } }
    }
}
