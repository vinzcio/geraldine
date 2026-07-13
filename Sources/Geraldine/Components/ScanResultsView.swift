import SwiftUI

/// Reusable grouped, selectable results list with a clean-action footer.
/// Used by Cleanup, Privacy, Uninstaller leftovers, and Large & Old Files.
struct ScanResultsView: View {
    let groups: [ScanGroup]
    @Binding var selection: Set<String>
    var diagnostics: ScanDiagnostics = .empty
    var actionTitle: String = "Move to Trash"
    var actionIcon: String = "trash"
    var isBusy: Bool = false
    var onClean: () -> Void

    private var selectedSize: UInt64 { groups.selectedSize(selection) }
    private var selectedCount: Int { groups.items(in: selection).count }

    var body: some View {
        VStack(spacing: 0) {
            if diagnostics.hasVisibleIssues {
                ScanDiagnosticsBanner(diagnostics: diagnostics)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            List {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    Section {
                        ForEach(group.items) { item in
                            row(item, in: group)
                        }
                    } header: {
                        groupHeader(group)
                    }
                    .geraldineEntrance(delay: min(Double(index) * 0.07, 0.21), distance: 6)
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
            Button(allSelected(group) ? "Deselect" : "Select All") {
                toggleGroup(group)
            }
            .buttonStyle(.quiet(group.tint))
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func row(_ item: ScanItem, in group: ScanGroup) -> some View {
        let isSelected = selection.contains(item.id)
        return Button {
            toggle(item.id)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                ContextualSymbol(inactive: "circle",
                                 active: "checkmark.circle.fill",
                                 isActive: isSelected,
                                 tint: group.tint,
                                 size: 17)

                identity(for: item, group: group)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                AnimatedNumberText(Fmt.size(item.size), value: Double(item.size))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Theme.Spacing.xxs)
            .padding(.horizontal, Theme.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.geraldineSelection(group.tint, isSelected: isSelected))
        .accessibilityLabel(item.name)
        .accessibilityValue("\(Fmt.size(item.size)), \(isSelected ? "selected" : "not selected")")
    }

    @ViewBuilder
    private func identity(for item: ScanItem, group: ScanGroup) -> some View {
        if let url = item.identityURL {
            AppIconPlate(size: 34) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            }
        } else {
            ModuleGlyph(systemImage: group.icon, tint: group.tint, size: 34)
        }
    }

    private var footer: some View {
        HStack {
            if selectedCount == 0 {
                Text("Nothing Selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    AnimatedNumberText("\(selectedCount)", value: Double(selectedCount))
                    Text(selectedCount == 1 ? "Item" : "Items")
                    Text("·")
                    AnimatedNumberText(Fmt.size(selectedSize), value: Double(selectedSize))
                    Text("Selected")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            Spacer()
            Button(action: onClean) {
                HStack(spacing: 7) {
                    if isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: actionIcon) }
                    Text(actionTitle).font(.rounded(14, .semibold))
                }
                .frame(minWidth: 126)
            }
            .buttonStyle(BrandProminentButtonStyle())
            .disabled(selectedCount == 0 || isBusy)
        }
        .padding(16)
        .adaptiveMaterialBackground(.ultraThin, in: Rectangle())
    }

    // MARK: helpers
    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    private func allSelected(_ group: ScanGroup) -> Bool {
        !group.items.isEmpty && group.items.allSatisfy { selection.contains($0.id) }
    }
    private func toggleGroup(_ group: ScanGroup) {
        let ids = group.items.map(\.id)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if allSelected(group) { ids.forEach { selection.remove($0) } }
            else { ids.forEach { selection.insert($0) } }
        }
    }
}

struct ScanDiagnosticsBanner: View {
    var diagnostics: ScanDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: diagnostics.cancelled ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(diagnostics.cancelled ? Color.secondary : Theme.warn)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                if let finishedAt = diagnostics.finishedAt {
                    Text(finishedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(message).font(.caption).foregroundStyle(.secondary)
            if let first = diagnostics.skipped.first {
                Text("\(first.path): \(first.message)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
            .background(Theme.decorativeFill(diagnostics.cancelled ? Color.secondary : Theme.warn),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                .strokeBorder(Theme.decorativeFill(
                    diagnostics.cancelled ? Color.secondary : Theme.warn,
                    strength: .strong
                ), lineWidth: 1)
        )
    }

    private var title: String {
        if diagnostics.cancelled { return "Scan Cancelled" }
        if diagnostics.failure != nil { return "Scan Failed" }
        return diagnostics.skipped.count == 1 ? "1 Path Skipped" : "\(diagnostics.skipped.count) Paths Skipped"
    }

    private var message: String {
        if let failure = diagnostics.failure { return failure }
        if diagnostics.cancelled { return "Results may be incomplete because the scan was stopped." }
        return "Geraldine could not read every path. Grant Full Disk Access if important locations are missing."
    }
}
