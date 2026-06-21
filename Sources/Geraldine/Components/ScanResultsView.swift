import SwiftUI

/// Reusable grouped, selectable results list with a clean-action footer.
/// Used by Cleanup, Privacy, Uninstaller leftovers, and Large & Old Files.
struct ScanResultsView: View {
    let groups: [ScanGroup]
    @Binding var selection: Set<UUID>
    var actionTitle: String = "Move to Trash"
    var actionIcon: String = "trash"
    var isBusy: Bool = false
    var onClean: () -> Void

    private var selectedSize: UInt64 { groups.selectedSize(selection) }
    private var selectedCount: Int { groups.items(in: selection).count }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            row(item)
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset)

            footer
        }
    }

    private func groupHeader(_ group: ScanGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.icon).foregroundStyle(group.tint)
            Text(group.title).font(.rounded(13, .semibold))
            Text(Fmt.size(group.totalSize)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(allSelected(group) ? "Deselect" : "Select all") {
                toggleGroup(group)
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 2)
    }

    private func row(_ item: ScanItem) -> some View {
        Button {
            toggle(item.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(item.id) ? Theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1)
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(Fmt.size(item.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text(selectedCount == 0 ? "Nothing selected"
                 : "\(selectedCount) items · \(Fmt.size(selectedSize)) selected")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(action: onClean) {
                HStack(spacing: 7) {
                    if isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: actionIcon) }
                    Text(actionTitle).font(.rounded(14, .semibold))
                }
                .padding(.horizontal, 18).padding(.vertical, 9)
                .foregroundStyle(.white)
                .background(selectedCount == 0 ? AnyShapeStyle(Color.gray.opacity(0.4))
                                               : AnyShapeStyle(Theme.brandGradient),
                            in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0 || isBusy)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    // MARK: helpers
    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    private func allSelected(_ group: ScanGroup) -> Bool {
        !group.items.isEmpty && group.items.allSatisfy { selection.contains($0.id) }
    }
    private func toggleGroup(_ group: ScanGroup) {
        let ids = group.items.map(\.id)
        if allSelected(group) { ids.forEach { selection.remove($0) } }
        else { ids.forEach { selection.insert($0) } }
    }
}
