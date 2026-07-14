import SwiftUI

struct PrivacyView: View {
    @StateObject private var vm = PrivacyViewModel()
    @State private var showSensitiveConfirmation = false
    @State private var cancellationMessage: String?
    @State private var cancellationClearTask: Task<Void, Never>?

    private enum VisualPhase: Hashable { case idle, scanning, review, done }

    private var visualPhase: VisualPhase {
        switch vm.phase {
        case .idle: .idle
        case .scanning: .scanning
        case .results, .cleaning: .review
        case .done: .done
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .privacy) {
                if vm.phase == .results || vm.phase == .done {
                    Button { rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .buttonStyle(.soft(Module.privacy.tint))
                }
            }

            WorkflowPhaseHost(phase: visualPhase) {
                switch vm.phase {
                case .idle:
                    PrivacyStart(action: startScan)
                case .scanning:
                    ScanningState(tint: Module.privacy.tint,
                                  icon: Module.privacy.systemImage,
                                  label: "Checking Your Browsers",
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
                                       action: rescan)
                    } else {
                        VStack(spacing: 0) {
                            PrivacySelectionSummary(isSensitive: vm.selectedIncludesCookiesOrHistory)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                            ScanResultsView(groups: vm.groups, selection: $vm.selection,
                                            diagnostics: vm.diagnostics,
                                            actionTitle: "Clean Selected",
                                            isBusy: vm.phase == .cleaning) {
                                if vm.selectedIncludesCookiesOrHistory {
                                    clearCancellation()
                                    showSensitiveConfirmation = true
                                } else {
                                    beginClean()
                                }
                            }
                            if let cancellationMessage {
                                CancellationReturnNotice(message: cancellationMessage)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 8)
                            }
                        }
                        .geraldineAnimation(.standard, value: cancellationMessage)
                    }
                case .done:
                    CleanDoneState(result: vm.result, again: rescan)
                }
            }
        }
        .confirmationDialog("Clean cookies and browsing history?",
                            isPresented: $showSensitiveConfirmation) {
            Button("Delete Cookies and History", role: .destructive) { beginClean() }
            Button("Cancel", role: .cancel) {
                noteCancellation("Cleanup cancelled · Browser data was not changed.")
            }
        } message: {
            Text("This removes selected cookie and history databases. You may be signed out of websites and browser history may not be recoverable.")
        }
        .onDisappear { cancellationClearTask?.cancel() }
    }

    private func startScan() {
        clearCancellation()
        vm.scan()
    }

    private func rescan() {
        clearCancellation()
        vm.reset()
        vm.scan()
    }

    private func beginClean() {
        clearCancellation()
        vm.clean()
    }

    private func clearCancellation() {
        cancellationClearTask?.cancel()
        cancellationClearTask = nil
        cancellationMessage = nil
    }

    private func noteCancellation(_ message: String) {
        cancellationClearTask?.cancel()
        cancellationMessage = message
        cancellationClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, cancellationMessage == message else { return }
            cancellationMessage = nil
            cancellationClearTask = nil
        }
    }
}

private struct PrivacyStart: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            WorkflowMark(state: .idle, tint: Module.privacy.tint,
                         idleIcon: "hand.raised.fill", size: 96)
            Text("Review Browser Traces")
                .font(.rounded(20, .semibold))
            Text("Caches are selected by default. Cookies and history stay off until you explicitly choose them, so Geraldine never signs you out by surprise.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: 10) {
                ForEach(BrowserIdentity.allCases) { browser in
                    if let url = browser.applicationURL {
                        AppIconPlate(size: 38) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .scaledToFit()
                                .padding(3)
                        }
                        .help(browser.rawValue)
                    }
                }
            }
            .frame(minHeight: 38)

            PrimaryButton(title: "Scan Browsers", icon: "magnifyingglass", action: action)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PrivacySelectionSummary: View {
    let isSensitive: Bool

    var body: some View {
        HStack(spacing: 10) {
            ContextualSymbol(inactive: "shippingbox.fill",
                             active: "exclamationmark.shield.fill",
                             isActive: isSensitive,
                             tint: isSensitive ? Theme.warn : Module.privacy.tint,
                             size: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(isSensitive ? "Sensitive Browser Data Selected" : "Cache-Only Cleanup")
                    .font(.caption.weight(.semibold))
                Text(isSensitive
                     ? "Cookies or history can sign you out or erase local records. Geraldine will confirm before cleaning."
                     : "Only disposable browser caches are selected. Cookies and history remain untouched.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(12)
        .background((isSensitive ? Theme.warn : Module.privacy.tint).opacity(0.09),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .geraldineAnimation(.standard, value: isSensitive)
    }
}
