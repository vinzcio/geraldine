import SwiftUI

struct AppEntry: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let size: UInt64
}

@MainActor
final class UninstallerViewModel: ObservableObject {
    @Published var apps: [AppEntry] = []
    @Published var loading = false
    @Published var query = ""

    var filtered: [AppEntry] {
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func load() {
        loading = true
        Task {
            self.apps = await Self.discover()
            self.loading = false
        }
    }

    private static func discover() async -> [AppEntry] {
        await Task.detached(priority: .userInitiated) { () -> [AppEntry] in
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let dirs = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/Applications/Utilities"),
                home.appendingPathComponent("Applications")
            ]
            var result: [AppEntry] = []
            for dir in dirs {
                guard let entries = try? fm.contentsOfDirectory(at: dir,
                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for url in entries where url.pathExtension == "app" {
                    let bundle = Bundle(url: url)
                    let bundleID = bundle?.bundleIdentifier ?? ""
                    let version = (bundle?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
                    let name = url.deletingPathExtension().lastPathComponent
                    result.append(AppEntry(url: url, name: name, bundleID: bundleID,
                                           version: version, size: DiskScan.size(of: url)))
                }
            }
            return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }
}

@MainActor
final class LeftoversModel: ObservableObject {
    enum Phase { case scanning, results, uninstalling, done }
    @Published var phase: Phase = .scanning
    @Published var groups: [ScanGroup] = []
    @Published var selection: Set<UUID> = []
    @Published var result: TrashService.Result?

    let app: AppEntry
    init(app: AppEntry) { self.app = app }

    func scan() {
        phase = .scanning
        Task {
            let g = await Self.findLeftovers(for: app)
            self.groups = g
            self.selection = g.allItemIDs   // pre-select everything for a clean removal
            self.phase = .results
        }
    }

    func uninstall() {
        let items = groups.items(in: selection)
        guard !items.isEmpty else { return }
        phase = .uninstalling
        Task {
            let r = await Task.detached { TrashService.clean(items) }.value
            self.result = r
            self.phase = .done
        }
    }

    private static func findLeftovers(for app: AppEntry) async -> [ScanGroup] {
        await Task.detached(priority: .userInitiated) { () -> [ScanGroup] in
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
            if let agents = try? fm.contentsOfDirectory(at: lib.appendingPathComponent("LaunchAgents"),
                                                        includingPropertiesForKeys: nil) {
                for a in agents where ids.contains(where: { a.lastPathComponent.contains($0) }) {
                    candidates.append(a)
                }
            }

            var seen = Set<String>()
            let leftovers = candidates
                .filter { fm.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
                .map { ScanItem(url: $0, name: $0.lastPathComponent,
                                detail: $0.deletingLastPathComponent().path, size: DiskScan.size(of: $0)) }
                .sorted { $0.size > $1.size }

            var groups = [appGroup]
            if !leftovers.isEmpty {
                groups.append(ScanGroup(title: "Leftover files", icon: "doc.on.doc.fill",
                                        tint: Theme.warn, items: leftovers))
            }
            return groups
        }.value
    }
}
