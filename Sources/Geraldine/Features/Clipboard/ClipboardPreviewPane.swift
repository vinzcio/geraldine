import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The right-hand half of the picker: the full contents of whatever is selected,
/// plus where it came from and when.
struct ClipboardPreviewPane: View {
    @ObservedObject var clipboard: ClipboardHistoryController
    let entry: ClipboardHistoryEntry?
    let pasteLabel: String
    let paste: (ClipboardHistoryEntry) -> Void

    @State private var content: ClipboardPreviewContent = .unavailable
    @State private var isLoading = false

    var body: some View {
        Group {
            if let entry {
                VStack(spacing: 0) {
                    preview(for: entry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    details(for: entry)
                }
            } else {
                Color.clear
            }
        }
        // Keyed on the selection so arrowing through the list cancels the read
        // that is already in flight instead of stacking them up.
        .task(id: entry?.id) {
            guard let entry else {
                content = .unavailable
                return
            }
            isLoading = true
            defer { isLoading = false }
            // Long enough that holding an arrow key does not hit the disk per row.
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            content = await clipboard.previewContent(for: entry)
        }
    }

    @ViewBuilder private func preview(for entry: ClipboardHistoryEntry) -> some View {
        switch content {
        case .image(let data):
            imagePreview(data: data)
        case .text(let text):
            textPreview(text)
        case .files(let urls):
            filesPreview(urls)
        case .color(let hex):
            colorPreview(hex)
        case .unavailable:
            placeholder(for: entry)
        }
    }

    /// Shown while the payload is read, and if it turns out to be unreadable.
    @ViewBuilder private func placeholder(for entry: ClipboardHistoryEntry) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            if let thumbnail = entry.thumbnail, let image = NSImage(data: thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .blur(radius: isLoading ? 4 : 0)
            } else {
                ModuleGlyph(systemImage: entry.kind.systemImage, tint: Module.clipboard.tint, size: 54)
            }
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text("Nothing to preview for this item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.lg)
    }

    private func imagePreview(data: Data) -> some View {
        ZStack {
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Theme.separator, lineWidth: 1)
                    }
            } else {
                Text("This image could not be decoded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private func textPreview(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.lg)
        }
    }

    private func filesPreview(_ urls: [URL]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(urls, id: \.self) { url in
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(nsImage: AppIcons.forFile(at: url) ?? NSWorkspace.shared.icon(for: .data))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(url.deletingLastPathComponent().path.removingPercentEncoding ?? url.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.lg)
        }
    }

    private func colorPreview(_ hex: String) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Color(hex: hex) ?? .clear)
                .frame(width: 160, height: 110)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                }
            Text(hex)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.lg)
    }

    private func details(for entry: ClipboardHistoryEntry) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                detailRow("Type", value: entry.kind.label)
                if let source = entry.sourceApplicationName {
                    detailRow("From", value: source)
                }
                detailRow("Copied", value: entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                if let lastUsed = entry.lastUsedAt {
                    detailRow("Last used", value: lastUsed.formatted(date: .abbreviated, time: .shortened))
                }
                detailRow("Size", value: entry.sizeDescription)
            }

            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                if entry.isPinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(Module.clipboard.tint)
                }
                Button {
                    paste(entry)
                } label: {
                    Label(pasteLabel, systemImage: "return")
                }
                .buttonStyle(.soft(Module.clipboard.tint, compact: true))
            }
            .fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        // Hug the rows; the preview above takes the leftover height.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
