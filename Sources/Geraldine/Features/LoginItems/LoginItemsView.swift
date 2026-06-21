import SwiftUI

struct LoginItemsView: View {
    @StateObject private var vm = LoginItemsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .loginItems) {
                Text("Changes apply at next login").font(.caption).foregroundStyle(.secondary)
            }

            if vm.loading && vm.items.isEmpty {
                ScanningState(tint: Module.loginItems.tint, label: "Reading startup items…")
            } else {
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
        .onAppear { if vm.items.isEmpty { vm.load() } }
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
                Button { vm.remove(item) } label: { Image(systemName: "trash").foregroundStyle(Theme.bad) }
                    .buttonStyle(.plain).help("Remove this startup item")
            } else {
                Text("Locked").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}
