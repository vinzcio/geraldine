import AppKit
import SwiftUI

struct ClipboardHistoryView: View {
    @EnvironmentObject private var clipboard: ClipboardHistoryController
    @State private var query = ""
    @State private var kind: ClipboardContentKind?
    @State private var pinnedOnly = false
    @State private var confirmingDeleteAll = false

    private var visibleEntries: [ClipboardHistoryEntry] {
        let matches = clipboard.matchingEntries(query: query, kind: kind)
        return pinnedOnly ? matches.filter(\.isPinned) : matches
    }

    var body: some View {
        ModulePage(
            module: .clipboard,
            title: "Clipboard History",
            subtitle: "Find and reuse what you copied, without leaving plaintext behind.",
            headerStyle: .utility,
            widthRole: .readable
        ) {
            Button {
                clipboard.requestPicker()
            } label: {
                Label("Open Clipboard Picker", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(.soft(Module.clipboard.tint))
        } content: {
            settingsCard
            statusContent
            historyCard
        }
        .confirmationDialog(
            "Delete all clipboard history?",
            isPresented: $confirmingDeleteAll
        ) {
            Button("Delete All History", role: .destructive) {
                clipboard.deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every encrypted clipboard entry stored on this Mac.")
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "History & Retention",
                subtitle: "Geraldine encrypts saved items locally. Pinned items are never removed by retention."
            )

            Toggle("Record clipboard history", isOn: $clipboard.isEnabled)
                .tint(Module.clipboard.tint)

            HStack(spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Keep history for")
                        .font(.geraldineLabel)
                    Text("Counted from the last time you used an item, not the first copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Keep history for", selection: $clipboard.retention) {
                    ForEach(ClipboardRetention.allCases) { retention in
                        Text(retention.label).tag(retention)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            Toggle("Enable Control–Option–V shortcut", isOn: $clipboard.shortcutEnabled)
                .tint(Module.clipboard.tint)

            HStack(spacing: Theme.Spacing.sm) {
                Label("AES-GCM encrypted", systemImage: "lock.fill")
                Label("Password apps excluded", systemImage: "eye.slash.fill")
                Label(storageSummary, systemImage: "tray.full.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .card(padding: Theme.Spacing.lg, tier: .tinted(Module.clipboard.tint))
    }

    private var storageSummary: String {
        let count = clipboard.entries.count
        let noun = count == 1 ? "item" : "items"
        guard count > 0 else { return "Nothing stored" }
        return "\(count) \(noun) · \(Fmt.size(Int64(clipboard.storedByteCount)))"
    }

    @ViewBuilder private var statusContent: some View {
        // Errors are sticky until dismissed, so notices get their own row rather
        // than being hidden behind a stale failure.
        if let error = clipboard.lastError {
            clipboardBanner(error, tint: Theme.bad, icon: "exclamationmark.triangle.fill") {
                clipboard.dismissError()
            }
        }
        if let notice = clipboard.notice {
            clipboardBanner(notice, tint: Module.clipboard.tint, icon: "info.circle.fill", dismiss: nil)
        }
    }

    private func clipboardBanner(
        _ message: String,
        tint: Color,
        icon: String,
        dismiss: (() -> Void)?
    ) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.quiet(.secondary, compact: true))
                .accessibilityLabel("Dismiss message")
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            Theme.decorativeFill(tint, strength: .subtle),
            in: RoundedRectangle(cornerRadius: Theme.Radius.control)
        )
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                SectionHeader(
                    "Saved Items",
                    subtitle: "Return an item to the system clipboard, pin it, or remove it."
                )
                if !clipboard.entries.isEmpty {
                    Button("Delete All", role: .destructive) {
                        confirmingDeleteAll = true
                    }
                    .buttonStyle(.quiet(Theme.bad))
                }
            }

            searchControls

            if !clipboard.isLoaded {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Opening encrypted history…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else if visibleEntries.isEmpty {
                EmptyState(
                    icon: clipboard.entries.isEmpty ? "clipboard" : "magnifyingglass",
                    title: clipboard.entries.isEmpty ? "Nothing Saved Yet" : "No Matching Items",
                    message: clipboard.entries.isEmpty
                        ? "Copy text, links, images, or files and Geraldine will keep them here."
                        : "Change the search or content filter.",
                    tint: Module.clipboard.tint
                )
                .frame(minHeight: 240)
            } else {
                LazyVStack(spacing: Theme.Spacing.xs) {
                    ForEach(visibleEntries) { entry in
                        ClipboardHistoryLedgerRow(
                            entry: entry,
                            restore: { Task { await clipboard.restore(entry) } },
                            togglePinned: { clipboard.togglePinned(entry) },
                            delete: { clipboard.delete(entry) }
                        )
                    }
                }
            }
        }
        .card(padding: Theme.Spacing.lg, tier: .raised)
    }

    private var searchControls: some View {
        HStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search saved items", text: $query)
                    .textFieldStyle(.plain)
                ClearSearchButton(query: $query)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: 34)
            .background(Theme.surfaceBase, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            }

            Picker("Type", selection: $kind) {
                Text("All Types").tag(Optional<ClipboardContentKind>.none)
                ForEach(ClipboardContentKind.allCases) { kind in
                    Text(kind.label).tag(Optional(kind))
                }
            }
            .frame(width: 140)

            Toggle(isOn: $pinnedOnly) {
                Image(systemName: pinnedOnly ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .help("Show pinned items only")
            .accessibilityLabel("Show pinned items only")
        }
    }
}

private struct ClipboardHistoryLedgerRow: View {
    let entry: ClipboardHistoryEntry
    let restore: () -> Void
    let togglePinned: () -> Void
    let delete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ClipboardEntryThumbnail(entry: entry, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.preview)
                    .font(.geraldineLabel)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ClipboardEntryMetaLine(entry: entry)
            }
            HStack(spacing: Theme.Spacing.xs) {
                Button(action: restore) {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.quiet(Module.clipboard.tint))
                .help("Restore to clipboard")
                .accessibilityLabel("Restore \(entry.preview)")

                Button(action: togglePinned) {
                    Image(systemName: entry.isPinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.quiet(entry.isPinned ? Module.clipboard.tint : .secondary))
                .help(entry.isPinned ? "Unpin" : "Pin")
                .accessibilityLabel(entry.isPinned ? "Unpin item" : "Pin item")

                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.quiet(Theme.bad))
                .help("Delete")
                .accessibilityLabel("Delete item")
            }
        }
        .padding(Theme.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isHovered ? Module.clipboard.tint.opacity(0.06) : Theme.surfaceBase)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(
                    entry.isPinned ? Module.clipboard.tint.opacity(0.35) : Theme.separator,
                    lineWidth: 1
                )
        }
        .onHover { isHovered = $0 }
        .geraldineAnimation(.quick, value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.accessibilityLabel)
    }
}
