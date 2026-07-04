import SwiftUI

struct UninstallerView: View {
    @StateObject private var vm = UninstallerViewModel()
    @State private var selectedApp: AppEntry?

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .uninstaller) {
                if !vm.apps.isEmpty {
                    Text("\(vm.apps.count) Apps").font(.callout).foregroundStyle(.secondary)
                }
            }

            if vm.loading {
                ScanningState(tint: Module.uninstaller.tint, icon: "app.badge",
                              label: "Finding installed apps…")
            } else {
                searchBar
                if vm.apps.isEmpty {
                    ScanEmptyState(icon: "app.badge",
                                   title: "No Apps Found",
                                   message: vm.diagnostics.hasVisibleIssues
                                       ? "Geraldine could not read every Applications folder."
                                       : "No removable apps were found in Applications.",
                                   tint: Module.uninstaller.tint,
                                   diagnostics: vm.diagnostics,
                                   actionTitle: "Check Again",
                                   action: vm.load)
                } else if vm.filtered.isEmpty {
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
                                AppCard(app: app) {
                                    if !app.isProtected { selectedApp = app }
                                }
                            }
                        }
                        .padding(20)
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
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 20).padding(.bottom, 4)
    }
}

private struct AppCard: View {
    var app: AppEntry
    var onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.rounded(14, .semibold)).lineLimit(1)
                Text("\(app.version.isEmpty ? "" : "v\(app.version) · ")\(Fmt.size(app.size))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let reason = app.protectedReason {
                    Text(reason).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onUninstall) {
                Image(systemName: app.isProtected ? "lock.fill" : "trash")
                    .foregroundStyle(app.isProtected ? Color.secondary : Theme.bad)
            }
            .buttonStyle(.plain)
            .disabled(app.isProtected)
            .help(app.protectedReason ?? "Uninstall \(app.name)")
            .pointingHandCursor()
        }
        .card(padding: 12)
    }
}

private struct LeftoversSheet: View {
    let app: AppEntry
    var onClose: (_ didUninstall: Bool) -> Void
    @StateObject private var model: LeftoversModel
    @State private var showUninstallConfirmation = false

    init(app: AppEntry, onClose: @escaping (Bool) -> Void) {
        self.app = app
        self.onClose = onClose
        _model = StateObject(wrappedValue: LeftoversModel(app: app))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Uninstall \(app.name)").font(.rounded(17, .bold))
                    Text("Review what will move to the Trash.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { onClose(false) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            switch model.phase {
            case .scanning:
                ScanningState(tint: Module.uninstaller.tint, icon: "doc.on.doc",
                              label: "Finding leftover files…")
                    .frame(height: 280)
            case .results, .uninstalling:
                if model.groups.isEmpty {
                    ScanEmptyState(icon: "lock.fill",
                                   title: "Protected App",
                                   message: model.diagnostics.failure ?? "Geraldine will not uninstall this app.",
                                   tint: Module.uninstaller.tint,
                                   diagnostics: model.diagnostics,
                                   actionTitle: "Close",
                                   action: { onClose(false) })
                        .frame(height: 320)
                } else {
                    ScanResultsView(groups: model.groups, selection: $model.selection,
                                    diagnostics: model.diagnostics,
                                    actionTitle: "Uninstall", actionIcon: "trash",
                                    isBusy: model.phase == .uninstalling) {
                        showUninstallConfirmation = true
                    }
                    .frame(height: 380)
                }
            case .done:
                CleanDoneState(result: model.result, again: { onClose(true) })
                .frame(height: 280)
            }
        }
        .frame(width: 520)
        .onAppear { model.scan() }
        .confirmationDialog("Uninstall \(app.name)?",
                            isPresented: $showUninstallConfirmation) {
            Button("Move App and Leftovers to Trash", role: .destructive) { model.uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Geraldine will move the selected app bundle and selected leftover files to the Trash. Quit \(app.name) first, and restore from Trash if this was a mistake.")
        }
    }
}
