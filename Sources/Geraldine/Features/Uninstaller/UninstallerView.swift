import SwiftUI

struct UninstallerView: View {
    @StateObject private var vm = UninstallerViewModel()
    @State private var selectedApp: AppEntry?

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 12)]

    private enum ContentPhase: Hashable { case loading, empty, loaded }

    private var contentPhase: ContentPhase {
        if vm.loading { return .loading }
        if vm.apps.isEmpty { return .empty }
        return .loaded
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .uninstaller) {
                if !vm.apps.isEmpty {
                    Text("\(vm.apps.count) Apps").font(.callout).foregroundStyle(.secondary)
                }
            }

            WorkflowPhaseHost(phase: contentPhase) {
                switch contentPhase {
                case .loading:
                    ScanningState(tint: Module.uninstaller.tint, icon: "app.badge",
                                  label: "Finding Installed Apps")
                case .empty:
                    ScanEmptyState(icon: "app.badge",
                                   title: "No Apps Found",
                                   message: vm.diagnostics.hasVisibleIssues
                                       ? "Geraldine could not read every Applications folder."
                                       : "No removable apps were found in Applications.",
                                   tint: Module.uninstaller.tint,
                                   diagnostics: vm.diagnostics,
                                   actionTitle: "Check Again",
                                   action: vm.load)
                case .loaded:
                    VStack(spacing: 0) {
                        searchBar
                        if vm.filtered.isEmpty {
                            EmptyState(icon: "magnifyingglass",
                                       title: "No Apps Match",
                                       message: "Try a different search term.",
                                       tint: Module.uninstaller.tint)
                        } else {
                            ScrollView {
                                if vm.diagnostics.hasVisibleIssues {
                                    ScanDiagnosticsBanner(diagnostics: vm.diagnostics)
                                        .padding(.horizontal, 20)
                                        .padding(.top, 8)
                                }
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(vm.filtered) { app in
                                        AppCard(app: app,
                                                isSelected: selectedApp?.id == app.id) {
                                            if !app.isProtected { selectedApp = app }
                                        }
                                    }
                                }
                                .padding(20)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { if vm.apps.isEmpty { vm.load() } }
        .sheet(item: $selectedApp) { app in
            LeftoversSheet(app: app) { didUninstall in
                selectedApp = nil
                if didUninstall { vm.load() }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search Apps", text: $vm.query).textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .adaptiveMaterialBackground(.ultraThin, in: Capsule())
        .padding(.horizontal, 20).padding(.bottom, 4)
    }
}

private struct AppCard: View {
    var app: AppEntry
    var isSelected: Bool
    var onUninstall: () -> Void

    var body: some View {
        Button(action: onUninstall) {
            HStack(spacing: 12) {
                AppIconPlate(size: 42) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable()
                        .scaledToFit()
                        .padding(3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.rounded(14, .semibold)).lineLimit(1)
                    Text("\(app.version.isEmpty ? "" : "v\(app.version) · ")\(Fmt.size(app.size))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let reason = app.protectedReason {
                        Text(reason).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ContextualSymbol(inactive: "trash",
                                 active: "lock.fill",
                                 isActive: app.isProtected,
                                 tint: app.isProtected ? .secondary : Theme.bad,
                                 size: 15)
                    .minimumHitArea()
            }
            .selectionPlate(isSelected: isSelected, tint: Module.uninstaller.tint)
        }
        .buttonStyle(.actionableCard(padding: 12))
        .disabled(app.isProtected)
        .help(app.protectedReason ?? "Uninstall \(app.name)")
    }
}

private struct LeftoversSheet: View {
    let app: AppEntry
    var onClose: (_ didUninstall: Bool) -> Void
    @StateObject private var model: LeftoversModel
    @State private var showUninstallConfirmation = false
    @State private var cancellationMessage: String?
    @State private var cancellationClearTask: Task<Void, Never>?

    private enum VisualPhase: Hashable { case scanning, review, done }

    private var visualPhase: VisualPhase {
        switch model.phase {
        case .scanning: .scanning
        case .results, .uninstalling: .review
        case .done: .done
        }
    }

    init(app: AppEntry, onClose: @escaping (Bool) -> Void) {
        self.app = app
        self.onClose = onClose
        _model = StateObject(wrappedValue: LeftoversModel(app: app))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIconPlate(size: 44) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable()
                        .scaledToFit()
                        .padding(3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Uninstall \(app.name)").font(.rounded(17, .bold))
                    Text("Review what will move to the Trash.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Report completion so a close after a finished uninstall still
                // refreshes the app grid, matching the Done button.
                Button { onClose(model.phase == .done) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.quiet(Module.uninstaller.tint))
                .disabled(model.phase == .uninstalling)
                .accessibilityLabel("Close uninstall review")
            }
            .padding(16)

            UninstallStepIndicator(phase: model.phase)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Divider()

            WorkflowPhaseHost(phase: visualPhase) {
                switch model.phase {
                case .scanning:
                    ScanningState(tint: Module.uninstaller.tint, icon: "doc.on.doc",
                                  label: "Finding Leftover Files")
                case .results, .uninstalling:
                    if model.groups.isEmpty {
                        ScanEmptyState(icon: "lock.fill",
                                       title: "Protected App",
                                       message: model.diagnostics.failure ?? "Geraldine will not uninstall this app.",
                                       tint: Module.uninstaller.tint,
                                       diagnostics: model.diagnostics,
                                       actionTitle: "Close",
                                       action: { onClose(false) })
                    } else {
                        VStack(spacing: 0) {
                            if let cancellationMessage {
                                CancellationReturnNotice(message: cancellationMessage)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 8)
                            }
                            ScanResultsView(groups: model.groups, selection: $model.selection,
                                            diagnostics: model.diagnostics,
                                            actionTitle: "Uninstall", actionIcon: "trash",
                                            isBusy: model.phase == .uninstalling) {
                                clearCancellation()
                                showUninstallConfirmation = true
                            }
                        }
                        .geraldineAnimation(.standard, value: cancellationMessage)
                    }
                case .done:
                    CleanDoneState(result: model.result,
                                   actionTitle: "Done",
                                   actionIcon: "checkmark",
                                   again: { onClose(true) })
                }
            }
            .frame(height: 380)
        }
        .frame(width: 520)
        .onAppear { model.scan() }
        .onDisappear { cancellationClearTask?.cancel() }
        .confirmationDialog("Uninstall \(app.name)?",
                            isPresented: $showUninstallConfirmation) {
            Button("Move App and Leftovers to Trash", role: .destructive) { beginUninstall() }
            Button("Cancel", role: .cancel) {
                noteCancellation("Uninstall cancelled · \(app.name) and its leftovers were not changed.")
            }
        } message: {
            Text("Geraldine will move the selected app bundle and selected leftover files to the Trash. Quit \(app.name) first, and restore from Trash if this was a mistake.")
        }
    }

    private func beginUninstall() {
        clearCancellation()
        model.uninstall()
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

private struct UninstallStepIndicator: View {
    let phase: LeftoversModel.Phase

    private var step: Int {
        switch phase {
        case .scanning: 1
        case .results, .uninstalling: 2
        case .done: 3
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            stepView(1, title: "App")
            connector(after: 1)
            stepView(2, title: "Leftovers")
            connector(after: 2)
            stepView(3, title: "Complete")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uninstall step \(step) of 3")
        .accessibilityValue(step == 1 ? "Inspecting app" : step == 2 ? "Reviewing leftovers" : "Complete")
    }

    private func stepView(_ index: Int, title: String) -> some View {
        HStack(spacing: 5) {
            ContextualSymbol(inactive: "\(index).circle",
                             active: "checkmark.circle.fill",
                             isActive: step > index || (step == 3 && index == 3),
                             tint: step >= index ? Module.uninstaller.tint : .secondary,
                             size: 14)
            Text(title)
                .font(.caption2.weight(step == index ? .semibold : .regular))
                .foregroundStyle(step >= index ? Color.primary : .secondary)
        }
    }

    private func connector(after index: Int) -> some View {
        Capsule()
            .fill(step > index ? Module.uninstaller.tint.opacity(0.55) : Theme.separator)
            .frame(maxWidth: .infinity)
            .frame(height: 2)
            .geraldineAnimation(.standard, value: step)
    }
}
