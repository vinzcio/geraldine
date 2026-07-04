import SwiftUI

@MainActor
final class PrivacyViewModel: ObservableObject {
    enum Phase { case idle, scanning, results, cleaning, done }

    @Published var phase: Phase = .idle
    @Published var groups: [ScanGroup] = []
    @Published var selection: Set<UUID> = []
    @Published var result: TrashService.Result?
    @Published var diagnostics: ScanDiagnostics = .empty

    private var scanTask: Task<ScanReport, Never>?
    private var scanID = UUID()

    var scanProgressText: String { "Checking Safari, Chromium browsers, and Firefox profiles." }
    var emptyMessage: String {
        diagnostics.hasVisibleIssues
            ? "No removable browser data was found in the locations Geraldine could read."
            : "Browser caches, cookies, and history look clear right now."
    }
    var selectedIncludesCookiesOrHistory: Bool {
        groups.contains { group in
            (group.title.contains("Cookies") || group.title.contains("History"))
                && group.items.contains { selection.contains($0.id) }
        }
    }

    func scan() {
        scanTask?.cancel()
        let id = UUID()
        scanID = id
        diagnostics = .empty
        result = nil
        phase = .scanning
        let worker = Task.detached(priority: .userInitiated) { Self.buildGroups() }
        scanTask = worker
        Task {
            let report = await worker.value
            guard self.scanID == id else { return }
            self.scanTask = nil
            self.groups = report.groups
            self.selection = report.groups.defaultSelection
            self.diagnostics = report.diagnostics
            self.phase = .results
        }
    }

    func cancelScan() {
        scanID = UUID()
        scanTask?.cancel()
        scanTask = nil
        groups = []
        selection = []
        diagnostics = .cancelledScan()
        phase = .results
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

    func reset() {
        scanID = UUID()
        scanTask?.cancel()
        scanTask = nil
        groups = []; selection = []; result = nil; diagnostics = .empty; phase = .idle
    }

    private nonisolated static func buildGroups() -> ScanReport {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let caches = home.appendingPathComponent("Library/Caches")
        let support = home.appendingPathComponent("Library/Application Support")
        var diagnostics = ScanDiagnostics()

        var cacheItems: [ScanItem] = []
        var cookieItems: [ScanItem] = []
        var historyItems: [ScanItem] = []

        func item(_ browser: String, _ category: String, _ url: URL) -> ScanItem? {
            guard !Task.isCancelled, fm.fileExists(atPath: url.path) else { return nil }
            let size = DiskScan.size(of: url, diagnostics: &diagnostics)
            diagnostics.noteScanned()
            return ScanItem(url: url, name: browser, detail: category, size: size)
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
        if fm.fileExists(atPath: ffProfiles.path) {
            do {
                let profiles = try fm.contentsOfDirectory(at: ffProfiles, includingPropertiesForKeys: nil)
                for p in profiles {
                    if Task.isCancelled { break }
                    cache("Firefox", caches.appendingPathComponent("Firefox/Profiles/\(p.lastPathComponent)"))
                    cookie("Firefox", p.appendingPathComponent("cookies.sqlite"))
                    history("Firefox", p.appendingPathComponent("places.sqlite"))
                }
            } catch {
                diagnostics.noteSkipped(ffProfiles, error)
            }
        }

        var groups: [ScanGroup] = []
        if !cacheItems.isEmpty {
            groups.append(ScanGroup(title: "Browser Caches", icon: "shippingbox.fill",
                                    tint: Theme.accent2,
                                    items: cacheItems.sorted { $0.size > $1.size }, safeByDefault: true))
        }
        if !cookieItems.isEmpty {
            groups.append(ScanGroup(title: "Cookies (Logs You Out)", icon: "circle.grid.cross.fill",
                                    tint: Theme.warn,
                                    items: cookieItems.sorted { $0.size > $1.size }, safeByDefault: false))
        }
        if !historyItems.isEmpty {
            groups.append(ScanGroup(title: "Browsing History", icon: "clock.arrow.circlepath",
                                    tint: Module.privacy.tint,
                                    items: historyItems.sorted { $0.size > $1.size }, safeByDefault: false))
        }
        diagnostics.finish(cancelled: Task.isCancelled)
        return ScanReport(groups: groups, diagnostics: diagnostics)
    }
}
