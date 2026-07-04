import SwiftUI

struct LoginItemsView: View {
    @StateObject private var vm = LoginItemsViewModel()
    @State private var pendingRemoval: LaunchItem?

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .loginItems) {
                Text("Changes Apply At Next Login").font(.caption).foregroundStyle(.secondary)
            }

            if vm.loading && vm.items.isEmpty {
                ScanningState(tint: Module.loginItems.tint, icon: Module.loginItems.systemImage,
                              label: "Reading startup items…")
            } else {
                if vm.items.isEmpty {
                    ScanEmptyState(icon: "powerplug",
                                   title: "No Login Items Found",
                                   message: vm.diagnostics.hasVisibleIssues
                                       ? "Geraldine could not read every startup item location."
                                       : "No editable or system startup items were found.",
                                   tint: Module.loginItems.tint,
                                   diagnostics: vm.diagnostics,
                                   actionTitle: "Check Again",
                                   action: vm.load)
                } else {
                    VStack(spacing: 0) {
                        if let lastError = vm.lastError {
                            LoginItemsBanner(message: lastError)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                        } else if vm.diagnostics.hasVisibleIssues {
                            ScanDiagnosticsBanner(diagnostics: vm.diagnostics)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                        }
                        List {
                            ForEach(LaunchItem.Scope.allCases, id: \.self) { scope in
                                let rows = vm.items(in: scope)
                                if !rows.isEmpty {
                                    Section(scope.rawValue) {
                                        ForEach(rows) { item in row(item) }
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)
                    }
                }
            }
        }
        .onAppear { if vm.items.isEmpty { vm.load() } }
        .confirmationDialog("Remove login item?",
                            isPresented: Binding(
                                get: { pendingRemoval != nil },
                                set: { if !$0 { pendingRemoval = nil } }
                            )) {
            Button("Move Login Item to Trash", role: .destructive) {
                if let item = pendingRemoval { vm.remove(item) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This moves the selected LaunchAgent plist to the Trash. The app or helper will stop launching automatically at your next login.")
        }
    }

    private func row(_ item: LaunchItem) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.editable ? "power" : "lock.fill")
                .foregroundStyle(item.editable ? Module.loginItems.tint : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.callout.weight(.medium)).lineLimit(1)
                if !item.program.isEmpty {
                    Text(item.program).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if item.editable {
                Toggle("", isOn: Binding(get: { item.enabled }, set: { _ in vm.toggle(item) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                Button { pendingRemoval = item } label: { Image(systemName: "trash").foregroundStyle(Theme.bad) }
                    .buttonStyle(.plain).help("Remove this startup item")
            } else {
                Text("Locked").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct LoginItemsBanner: View {
    var message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(Theme.warn.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
