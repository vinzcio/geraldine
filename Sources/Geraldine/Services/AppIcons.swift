import AppKit

/// Cached Launch Services icon lookups.
///
/// `urlForApplication(withBundleIdentifier:)` is a cross-process query and
/// `icon(forFile:)` rasterizes a bundle resource, so calling either from a
/// SwiftUI `body` costs a round trip per row per render. Long lists re-render on
/// every keystroke, which turns that into hundreds of main-thread queries for a
/// handful of distinct apps.
enum AppIcons {
    private static let byBundleIdentifier = NSCache<NSString, NSImage>()
    private static let byPath = NSCache<NSString, NSImage>()

    /// Icon for an installed application. Nil when the app is not present, so
    /// the caller can fall back to a glyph.
    static func forBundleIdentifier(_ bundleIdentifier: String) -> NSImage? {
        let key = bundleIdentifier as NSString
        if let cached = byBundleIdentifier.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        byBundleIdentifier.setObject(icon, forKey: key)
        return icon
    }

    /// Finder icon for a file. Nil when the file is gone.
    static func forFile(at url: URL) -> NSImage? {
        let path = url.path
        if let cached = byPath.object(forKey: path as NSString) { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        byPath.setObject(icon, forKey: path as NSString)
        return icon
    }
}
