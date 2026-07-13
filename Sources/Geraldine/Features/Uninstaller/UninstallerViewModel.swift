import SwiftUI

struct AppEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let size: UInt64
    let protectedReason: String?

    var id: String { url.standardizedFileURL.path }
    var isProtected: Bool { protectedReason != nil }
}

@MainActor
final class UninstallerViewModel: ObservableObject {
    @Published var apps: [AppEntry] = []
    @Published var loading = false
    @Published var query = ""
    @Published var diagnostics: ScanDiagnostics = .empty

    var filtered: [AppEntry] {
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func load() {
        loading = true
        diagnostics = .empty
        Task {
            let report = await Task.detached(priority: .userInitiated) { Self.discover() }.value
            self.apps = report.apps
            self.diagnostics = report.diagnostics
            self.loading = false
        }
    }

    private nonisolated static func discover() -> UninstallerDiscovery {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications")
        ]
        var result: [AppEntry] = []
        var diagnostics = ScanDiagnostics()
        for dir in dirs {
            do {
                let entries = try fm.contentsOfDirectory(at: dir,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])
                for url in entries where url.pathExtension == "app" {
                    diagnostics.noteScanned()
                    let bundle = Bundle(url: url)
                    let bundleID = bundle?.bundleIdentifier ?? ""
                    let version = (bundle?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
                    let name = url.deletingPathExtension().lastPathComponent
                    result.append(AppEntry(url: url, name: name, bundleID: bundleID,
                                           version: version,
                                           size: DiskScan.size(of: url, diagnostics: &diagnostics),
                                           protectedReason: protectionReason(url: url, bundleID: bundleID)))
                }
            } catch {
                diagnostics.noteSkipped(dir, error)
            }
        }
        diagnostics.finish()
        return UninstallerDiscovery(
            apps: result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            diagnostics: diagnostics
        )
    }

    private nonisolated static func protectionReason(url: URL, bundleID: String) -> String? {
        let path = url.standardizedFileURL.path
        if bundleID.hasPrefix("com.apple.") { return "Protected Apple App" }
        if path.hasPrefix("/System/Applications/") { return "Protected System App" }
        if path.hasPrefix("/Applications/Utilities/") { return "Protected macOS Utility" }
        return nil
    }
}

private struct UninstallerDiscovery {
    var apps: [AppEntry]
    var diagnostics: ScanDiagnostics
}

@MainActor
final class LeftoversModel: ObservableObject {
    enum Phase: Hashable { case scanning, results, uninstalling, done }
    @Published var phase: Phase = .scanning
    @Published var groups: [ScanGroup] = []
    @Published var selection: Set<String> = []
    @Published var result: TrashService.Result?
    @Published var diagnostics: ScanDiagnostics = .empty

    let app: AppEntry
    init(app: AppEntry) { self.app = app }

    func scan() {
        phase = .scanning
        let app = self.app
        Task {
            let report = await Task.detached(priority: .userInitiated) { Self.findLeftovers(for: app) }.value
            self.groups = report.groups
            self.selection = report.groups.allItemIDs   // pre-select everything for a clean removal
            self.diagnostics = report.diagnostics
            self.phase = .results
        }
    }

    func uninstall() {
        guard !app.isProtected else { return }
        let items = groups.items(in: selection)
        guard !items.isEmpty else { return }
        phase = .uninstalling
        Task {
            let r = await Task.detached { TrashService.clean(items) }.value
            self.result = r
            self.phase = .done
        }
    }

    private nonisolated static func findLeftovers(for app: AppEntry) -> ScanReport {
        var diagnostics = ScanDiagnostics()
        guard !app.isProtected else {
            diagnostics.failure = app.protectedReason ?? "This app is protected."
            diagnostics.finish()
            return ScanReport(groups: [], diagnostics: diagnostics)
        }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let lib = home.appendingPathComponent("Library")

        // The app bundle itself.
        let appGroup = ScanGroup(
            title: "Application", icon: "app.fill", tint: Module.uninstaller.tint,
            items: [ScanItem(url: app.url, name: app.url.lastPathComponent,
                             detail: app.url.deletingLastPathComponent().path, size: app.size)]
        )

        // Candidate leftover locations keyed by bundle id and app name.
        let ids = [app.bundleID, app.name].filter { !$0.isEmpty }
        var candidates: [URL] = []
        func add(_ relDir: String, _ leaf: String, ext: String? = nil) {
            let base = lib.appendingPathComponent(relDir).appendingPathComponent(leaf)
            candidates.append(ext.map { base.appendingPathExtension($0) } ?? base)
        }
        for key in ids {
            add("Application Support", key)
            add("Caches", key)
            add("Containers", key)
            add("HTTPStorages", key)
            add("Logs", key)
            add("Preferences", key, ext: "plist")
            add("Saved Application State", key, ext: "savedState")
            add("WebKit", key)
            add("Group Containers", key)
        }
        // Wildcard LaunchAgents matching the bundle id.
        let launchAgents = lib.appendingPathComponent("LaunchAgents")
        if fm.fileExists(atPath: launchAgents.path) {
            do {
                let agents = try fm.contentsOfDirectory(at: launchAgents, includingPropertiesForKeys: nil)
                for a in agents where ids.contains(where: { a.lastPathComponent.contains($0) }) {
                    candidates.append(a)
                }
            } catch {
                diagnostics.noteSkipped(launchAgents, error)
            }
        }

        var seen = Set<String>()
        let leftovers = candidates
            .filter { fm.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
            .map {
                diagnostics.noteScanned()
                return ScanItem(url: $0, name: $0.lastPathComponent,
                                detail: $0.deletingLastPathComponent().path,
                                size: DiskScan.size(of: $0, diagnostics: &diagnostics))
            }
            .sorted { $0.size > $1.size }

        var groups = [appGroup]
        if !leftovers.isEmpty {
            groups.append(ScanGroup(title: "Leftover Files", icon: "doc.on.doc.fill",
                                    tint: Theme.warn, items: leftovers))
        }
        diagnostics.finish()
        return ScanReport(groups: groups, diagnostics: diagnostics)
    }
}
