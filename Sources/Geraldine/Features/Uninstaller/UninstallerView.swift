import SwiftUI

struct UninstallerView: View {
    @StateObject private var vm = UninstallerViewModel()
    @State private var selectedApp: AppEntry?

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .uninstaller) {
                if !vm.apps.isEmpty {
                    Text("\(vm.apps.count) apps").font(.callout).foregroundStyle(.secondary)
                }
            }

            if vm.loading {
                ScanningState(tint: Module.uninstaller.tint, label: "Finding installed apps…")
            } else {
                searchBar
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(vm.filtered) { app in
                            AppCard(app: app) { selectedApp = app }
                        }
                    }
                    .padding(20)
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
            TextField("Search apps", text: $vm.query).textFieldStyle(.plain)
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
            }
            Spacer()
            Button(action: onUninstall) {
                Image(systemName: "trash").foregroundStyle(Theme.bad)
            }
            .buttonStyle(.plain)
            .help("Uninstall \(app.name)")
        }
        .card(padding: 12)
    }
}

private struct LeftoversSheet: View {
    let app: AppEntry
    var onClose: (_ didUninstall: Bool) -> Void
    @StateObject private var model: LeftoversModel

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
                ScanningState(tint: Module.uninstaller.tint, label: "Finding leftover files…")
                    .frame(height: 280)
            case .results, .uninstalling:
                ScanResultsView(groups: model.groups, selection: $model.selection,
                                actionTitle: "Uninstall", actionIcon: "trash",
                                isBusy: model.phase == .uninstalling, onClean: model.uninstall)
                    .frame(height: 360)
            case .done:
                CleanDoneState(result: model.result, again: { onClose(true) })
                    .frame(height: 280)
            }
        }
        .frame(width: 520)
        .onAppear { model.scan() }
    }
}
