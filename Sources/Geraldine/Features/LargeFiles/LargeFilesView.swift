import SwiftUI

struct LargeFilesView: View {
    @StateObject private var vm = LargeFilesViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .largeFiles) {
                if vm.phase == .results || vm.phase == .done {
                    Button { vm.reset() } label: { Label("New Scan", systemImage: "arrow.clockwise") }
                }
            }

            switch vm.phase {
            case .idle:    setup
            case .scanning:
                ScanningState(tint: Module.largeFiles.tint,
                              icon: Module.largeFiles.systemImage,
                              label: "Scanning \(vm.root.lastPathComponent)…",
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

    private var setup: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Module.largeFiles.tint.opacity(0.12)).frame(width: 96, height: 96)
                Image(systemName: Module.largeFiles.systemImage).font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Module.largeFiles.tint)
            }
            Text("Find Your Biggest Files").font(.rounded(20, .semibold))
            Text("Geraldine lists files over a size you choose, plus anything you haven't touched in a year — so nothing gets deleted by surprise.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Module.largeFiles.tint)
                    Text(vm.root.path).lineLimit(1).truncationMode(.middle).font(.callout)
                    Spacer()
                    Button("Choose…") { vm.chooseFolder() }
                }
                .card(padding: 12)

                HStack {
                    Text("Minimum Size").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $vm.minSizeMB) {
                        Text("50 MB").tag(50.0)
                        Text("100 MB").tag(100.0)
                        Text("500 MB").tag(500.0)
                        Text("1 GB").tag(1000.0)
                    }
                    .labelsHidden().frame(width: 110)
                }
                .card(padding: 12)
            }
            .frame(maxWidth: 460)

            PrimaryButton(title: "Scan", icon: "magnifyingglass", action: vm.scan).padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
