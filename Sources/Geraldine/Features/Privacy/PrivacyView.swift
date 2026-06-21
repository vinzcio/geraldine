import SwiftUI

struct PrivacyView: View {
    @StateObject private var vm = PrivacyViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .privacy) {
                if vm.phase == .results || vm.phase == .done {
                    Button { vm.reset(); vm.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                }
            }

            switch vm.phase {
            case .idle:
                ScanStart(module: .privacy,
                          message: "Geraldine finds cached data, cookies, and history for the browsers you use. Caches are pre-selected; cookies and history stay unchecked so you don't get logged out by accident.",
                          action: vm.scan)
            case .scanning:
                ScanningState(tint: Module.privacy.tint, label: "Checking your browsers…")
            case .results, .cleaning:
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent2)
                        Text("Quit your browsers first so files aren't in use.").font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.accent2.opacity(0.08))
                    ScanResultsView(groups: vm.groups, selection: $vm.selection,
                                    isBusy: vm.phase == .cleaning, onClean: vm.clean)
                }
            case .done:
                CleanDoneState(result: vm.result, again: { vm.reset(); vm.scan() })
            }
        }
    }
}
