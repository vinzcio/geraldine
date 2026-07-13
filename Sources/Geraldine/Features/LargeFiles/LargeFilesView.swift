import SwiftUI

struct LargeFilesView: View {
    @StateObject private var vm = LargeFilesViewModel()

    private enum VisualPhase: Hashable { case setup, scanning, review, done }

    private var visualPhase: VisualPhase {
        switch vm.phase {
        case .idle: .setup
        case .scanning: .scanning
        case .results, .cleaning: .review
        case .done: .done
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .largeFiles) {
                if vm.phase == .results || vm.phase == .done {
                    Button { vm.reset() } label: { Label("New Scan", systemImage: "arrow.clockwise") }
                }
            }

            WorkflowPhaseHost(phase: visualPhase) {
                switch vm.phase {
                case .idle: setup
                case .scanning:
                    ScanningState(tint: Module.largeFiles.tint,
                                  icon: Module.largeFiles.systemImage,
                                  label: "Scanning \(vm.root.lastPathComponent)",
                                  progressText: vm.scanProgressText,
                                  onCancel: vm.cancelScan)
                case .results, .cleaning:
                    if vm.groups.isEmpty {
                        ScanEmptyState(icon: "doc.text.magnifyingglass",
                                       title: "No Matching Files Found",
                                       message: vm.emptyMessage,
                                       tint: Module.largeFiles.tint,
                                       diagnostics: vm.diagnostics,
                                       actionTitle: "New Scan",
                                       action: vm.reset)
                    } else {
                        ScanResultsView(groups: vm.groups, selection: $vm.selection,
                                        diagnostics: vm.diagnostics,
                                        isBusy: vm.phase == .cleaning,
                                        onClean: vm.clean)
                    }
                case .done:
                    CleanDoneState(result: vm.result, again: { vm.reset() })
                }
            }
        }
    }

    private var setup: some View {
        VStack(spacing: 18) {
            Spacer()
            WorkflowMark(state: .idle, tint: Module.largeFiles.tint,
                         idleIcon: Module.largeFiles.systemImage, size: 96)
            Text("Find Your Biggest Files").font(.rounded(20, .semibold))
            Text("Geraldine lists files over a size you choose, plus anything you haven't touched in a year — so nothing gets deleted by surprise.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ModuleGlyph(systemImage: "folder.fill", tint: Module.largeFiles.tint, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Included Folder")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(vm.root.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.callout.weight(.medium))
                    }
                    Spacer()
                    Button("Choose Folder") { vm.chooseFolder() }
                        .buttonStyle(.soft(Module.largeFiles.tint))
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Minimum Size")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text(vm.thresholdLabel)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Module.largeFiles.tint)
                    }
                    Picker("", selection: $vm.minSizeMB) {
                        Text("50 MB").tag(50.0)
                        Text("100 MB").tag(100.0)
                        Text("500 MB").tag(500.0)
                        Text("1 GB").tag(1000.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    ScopeScaleIndicator(value: vm.minSizeMB)

                    Text("Files at or above the threshold are shown with older files over 5 MB. Nothing is pre-selected or removed until you review it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 460)
            .card(padding: 16, tier: .tinted(Module.largeFiles.tint))

            PrimaryButton(title: "Scan", icon: "magnifyingglass", action: vm.scan).padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScopeScaleIndicator: View {
    let value: Double
    private let stops = [50.0, 100.0, 500.0, 1_000.0]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(stops, id: \.self) { stop in
                Capsule()
                    .fill(stop <= value ? Module.largeFiles.tint : Theme.surfaceMuted)
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}
