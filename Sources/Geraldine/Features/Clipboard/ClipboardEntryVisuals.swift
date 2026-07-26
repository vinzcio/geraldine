import AppKit
import SwiftUI

/// The leading visual for a clipboard entry: the content itself where we can show
/// it (image thumbnail, colour swatch), otherwise the kind glyph — with the source
/// app badged in the corner so provenance survives either way.
struct ClipboardEntryThumbnail: View {
    let entry: ClipboardHistoryEntry
    var size: CGFloat = 38

    private var badgeSize: CGFloat { max(14, size * 0.42) }

    var body: some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let icon = Self.sourceIcon(for: entry) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: badgeSize, height: badgeSize)
                        .background(
                            Circle()
                                .fill(Theme.surfaceRaised)
                                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
                        )
                        .offset(x: badgeSize * 0.28, y: badgeSize * 0.28)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if let image = Self.thumbnailImage(for: entry) {
            AppIconPlate(size: size) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        } else if let hex = entry.colorHex, let color = Color(hex: hex) {
            AppIconPlate(size: size) {
                color
            }
        } else {
            ModuleGlyph(systemImage: entry.kind.systemImage, tint: Module.clipboard.tint, size: size)
        }
    }

    private static func sourceIcon(for entry: ClipboardHistoryEntry) -> NSImage? {
        guard let bundleIdentifier = entry.sourceBundleIdentifier else { return nil }
        return AppIcons.forBundleIdentifier(bundleIdentifier)
    }

    /// Decoding the stored PNG on every render costs a full decode per visible
    /// row, and the list re-renders on each keystroke in the search field.
    private static let thumbnailCache = NSCache<NSUUID, NSImage>()
    private static func thumbnailImage(for entry: ClipboardHistoryEntry) -> NSImage? {
        guard let thumbnail = entry.thumbnail else { return nil }
        let key = entry.id as NSUUID
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let image = NSImage(data: thumbnail) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }
}

/// The dimmed line under an entry's preview text.
struct ClipboardEntryMetaLine: View {
    enum Style {
        /// `Kind • Source • 2 min ago • 14 KB` — the roomy module list.
        case full
        /// `Kind • 2 min ago` — the picker's narrow column, where the source app
        /// is already shown as a badge on the thumbnail.
        case compact
    }

    let entry: ClipboardHistoryEntry
    var style: Style = .full

    /// Sub-kilobyte entries add noise more than information in a dense list.
    private static let sizeFloor = 1_024

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(entry.kind.label)
            if style == .full, let source = entry.sourceApplicationName {
                Text("•")
                Text(source)
            }
            Text("•")
            Text(entry.effectiveDate, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
            if style == .full, entry.byteCount >= Self.sizeFloor {
                Text("•")
                Text(entry.sizeDescription)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// A keycap plus what it does, for the picker's hint bar.
struct ClipboardShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 12)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.surfaceRaised)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Theme.separator, lineWidth: 1)
                        }
                }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(keys)")
    }
}

/// The trailing "clear" affordance both clipboard search fields use.
struct ClearSearchButton: View {
    @Binding var query: String

    var body: some View {
        if !query.isEmpty {
            Button {
                query = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
        }
    }
}

extension Color {
    /// Parses the `#RRGGBB` form stored on colour entries.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
