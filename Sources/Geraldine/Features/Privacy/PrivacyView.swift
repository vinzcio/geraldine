import SwiftUI

struct PrivacyView: View {
    @StateObject private var vm = PrivacyViewModel()
    @State private var showSensitiveConfirmation = false

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
                ScanningState(tint: Module.privacy.tint,
                              icon: Module.privacy.systemImage,
                              label: "Checking your browsers…",
                              progressText: vm.scanProgressText,
                              onCancel: vm.cancelScan)
            case .results, .cleaning:
                if vm.groups.isEmpty {
                    ScanEmptyState(icon: "checkmark.shield.fill",
                                   title: "No Browser Cleanup Found",
                                   message: vm.emptyMessage,
                                   tint: Module.privacy.tint,
                                   diagnostics: vm.diagnostics,
                                   actionTitle: "Scan Again",
                                   action: { vm.reset(); vm.scan() })
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent2)
                            Text("Quit browsers first. Cookies and history can log you out or erase local browsing records.")
                                .font(.caption)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Theme.accent2.opacity(0.08))
                        ScanResultsView(groups: vm.groups, selection: $vm.selection,
                                        diagnostics: vm.diagnostics,
                                        actionTitle: "Clean Selected",
                                        isBusy: vm.phase == .cleaning) {
                            if vm.selectedIncludesCookiesOrHistory {
                                showSensitiveConfirmation = true
                            } else {
                                vm.clean()
                            }
                        }
                    }
                }
            case .done:
                CleanDoneState(result: vm.result, again: { vm.reset(); vm.scan() })
            }
        }
        .confirmationDialog("Clean cookies and browsing history?",
                            isPresented: $showSensitiveConfirmation) {
            Button("Delete Cookies and History", role: .destructive) { vm.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes selected cookie and history databases. You may be signed out of websites and browser history may not be recoverable.")
        }
    }
}
