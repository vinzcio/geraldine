import SwiftUI

@MainActor
final class PrivacyViewModel: ObservableObject {
    enum Phase { case idle, scanning, results, cleaning, done }

    @Published var phase: Phase = .idle
    @Published var groups: [ScanGroup] = []
    @Published var selection: Set<UUID> = []
    @Published var result: TrashService.Result?

    func scan() {
        phase = .scanning
        Task {
            let g = await Self.buildGroups()
            self.groups = g
            self.selection = g.defaultSelection
            self.phase = .results
        }
    }

    func clean() {
        let items = groups.items(in: selection)
        guard !items.isEmpty else { return }
        phase = .cleaning
        Task {
            self.result = await Task.detached { TrashService.clean(items) }.value
            self.phase = .done
        }
    }

    func reset() { groups = []; selection = []; result = nil; phase = .idle }

    private static func buildGroups() async -> [ScanGroup] {
        await Task.detached(priority: .userInitiated) { () -> [ScanGroup] in
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let caches = home.appendingPathComponent("Library/Caches")
            let support = home.appendingPathComponent("Library/Application Support")

            var cacheItems: [ScanItem] = []
            var cookieItems: [ScanItem] = []
            var historyItems: [ScanItem] = []

            func item(_ browser: String, _ category: String, _ url: URL) -> ScanItem? {
                guard fm.fileExists(atPath: url.path) else { return nil }
                return ScanItem(url: url, name: browser, detail: category, size: DiskScan.size(of: url))
            }
            func cache(_ b: String, _ u: URL)   { if let i = item(b, "Cache", u) { cacheItems.append(i) } }
            func cookie(_ b: String, _ u: URL)  { if let i = item(b, "Cookies", u) { cookieItems.append(i) } }
            func history(_ b: String, _ u: URL) { if let i = item(b, "History", u) { historyItems.append(i) } }

            // Safari
            cache("Safari", caches.appendingPathComponent("com.apple.Safari"))
            history("Safari", home.appendingPathComponent("Library/Safari/History.db"))

            // Chromium-family
            let chromium: [(String, String, String)] = [
                ("Chrome", "Google/Chrome", "Google/Chrome"),
                ("Brave", "BraveSoftware/Brave-Browser", "BraveSoftware/Brave-Browser"),
                ("Edge", "Microsoft Edge", "Microsoft Edge")
            ]
            for (name, cacheRel, supRel) in chromium {
                cache(name, caches.appendingPathComponent(cacheRel))
                let def = support.appendingPathComponent("\(supRel)/Default")
                cookie(name, def.appendingPathComponent("Cookies"))
                history(name, def.appendingPathComponent("History"))
            }

            // Firefox (profile folders have random names)
            let ffProfiles = support.appendingPathComponent("Firefox/Profiles")
            if let profiles = try? fm.contentsOfDirectory(at: ffProfiles, includingPropertiesForKeys: nil) {
                for p in profiles {
                    cache("Firefox", caches.appendingPathComponent("Firefox/Profiles/\(p.lastPathComponent)"))
                    cookie("Firefox", p.appendingPathComponent("cookies.sqlite"))
                    history("Firefox", p.appendingPathComponent("places.sqlite"))
                }
            }

            var groups: [ScanGroup] = []
            if !cacheItems.isEmpty {
                groups.append(ScanGroup(title: "Browser Caches", icon: "shippingbox.fill",
                                        tint: Theme.accent2,
                                        items: cacheItems.sorted { $0.size > $1.size }, safeByDefault: true))
            }
            if !cookieItems.isEmpty {
                groups.append(ScanGroup(title: "Cookies (logs you out)", icon: "circle.grid.cross.fill",
                                        tint: Theme.warn,
                                        items: cookieItems.sorted { $0.size > $1.size }, safeByDefault: false))
            }
            if !historyItems.isEmpty {
                groups.append(ScanGroup(title: "Browsing History", icon: "clock.arrow.circlepath",
                                        tint: Module.privacy.tint,
                                        items: historyItems.sorted { $0.size > $1.size }, safeByDefault: false))
            }
            return groups
        }.value
    }
}
