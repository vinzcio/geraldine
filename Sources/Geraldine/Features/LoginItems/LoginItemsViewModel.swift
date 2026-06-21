import SwiftUI

struct LaunchItem: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let program: String
    let plistURL: URL
    let scope: Scope
    var enabled: Bool

    enum Scope: String, CaseIterable {
        case user = "Starts when you log in"
        case global = "Starts for all users"
        case daemon = "System services"
    }
    var editable: Bool { scope == .user }
}

@MainActor
final class LoginItemsViewModel: ObservableObject {
    @Published var items: [LaunchItem] = []
    @Published var loading = false

    private var disabledDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Geraldine/DisabledLaunchAgents")
    }
    private var userAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    func items(in scope: LaunchItem.Scope) -> [LaunchItem] {
        items.filter { $0.scope == scope }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func load() {
        loading = true
        try? FileManager.default.createDirectory(at: disabledDir, withIntermediateDirectories: true)
        let userDir = userAgentsDir, disDir = disabledDir
        Task {
            self.items = await Self.scan(userDir: userDir, disabledDir: disDir)
            self.loading = false
        }
    }

    func toggle(_ item: LaunchItem) {
        guard item.editable else { return }
        let fm = FileManager.default
        let dest = item.enabled
            ? disabledDir.appendingPathComponent(item.plistURL.lastPathComponent)
            : userAgentsDir.appendingPathComponent(item.plistURL.lastPathComponent)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: item.plistURL, to: dest)
            load()
        } catch { /* keep state on failure */ }
    }

    func remove(_ item: LaunchItem) {
        guard item.editable else { return }
        TrashService.clean([ScanItem(url: item.plistURL, size: 0)])
        load()
    }

    private static func scan(userDir: URL, disabledDir: URL) async -> [LaunchItem] {
        await Task.detached(priority: .userInitiated) { () -> [LaunchItem] in
            var out: [LaunchItem] = []
            func read(_ dir: URL, scope: LaunchItem.Scope, enabled: Bool) {
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil) else { return }
                for url in files where url.pathExtension == "plist" {
                    let dict = NSDictionary(contentsOf: url)
                    let label = (dict?["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
                    let program = (dict?["Program"] as? String)
                        ?? (dict?["ProgramArguments"] as? [String])?.first
                        ?? ""
                    out.append(LaunchItem(label: label, program: program, plistURL: url,
                                          scope: scope, enabled: enabled))
                }
            }
            read(userDir, scope: .user, enabled: true)
            read(disabledDir, scope: .user, enabled: false)
            read(URL(fileURLWithPath: "/Library/LaunchAgents"), scope: .global, enabled: true)
            read(URL(fileURLWithPath: "/Library/LaunchDaemons"), scope: .daemon, enabled: true)
            return out
        }.value
    }
}
