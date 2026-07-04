import SwiftUI

struct LaunchItem: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let program: String
    let plistURL: URL
    let scope: Scope
    var enabled: Bool

    enum Scope: String, CaseIterable {
        case user = "Starts When You Log In"
        case global = "Starts For All Users"
        case daemon = "System Services"
    }
    var editable: Bool { scope == .user }
}

@MainActor
final class LoginItemsViewModel: ObservableObject {
    @Published var items: [LaunchItem] = []
    @Published var loading = false
    @Published var diagnostics: ScanDiagnostics = .empty
    @Published var lastError: String?

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
        diagnostics = .empty
        try? FileManager.default.createDirectory(at: disabledDir, withIntermediateDirectories: true)
        let userDir = userAgentsDir, disDir = disabledDir
        Task {
            let report = await Task.detached(priority: .userInitiated) { Self.scan(userDir: userDir, disabledDir: disDir) }.value
            self.items = report.items
            self.diagnostics = report.diagnostics
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
            lastError = nil
            load()
        } catch {
            lastError = "Could not \(item.enabled ? "disable" : "enable") \(item.label): \((error as NSError).localizedDescription)"
        }
    }

    func remove(_ item: LaunchItem) {
        guard item.editable else { return }
        let result = TrashService.clean([ScanItem(url: item.plistURL, size: 0)])
        if let failure = result.failures.first {
            lastError = "Could not remove \(item.label): \(failure.message)"
        } else {
            lastError = nil
        }
        load()
    }

    private nonisolated static func scan(userDir: URL, disabledDir: URL) -> LoginItemsScanResult {
        var out: [LaunchItem] = []
        var diagnostics = ScanDiagnostics()
        let fm = FileManager.default
        func read(_ dir: URL, scope: LaunchItem.Scope, enabled: Bool) {
            guard fm.fileExists(atPath: dir.path) else { return }
            do {
                let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                for url in files where url.pathExtension == "plist" {
                    diagnostics.noteScanned()
                    let dict = NSDictionary(contentsOf: url)
                    let label = (dict?["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
                    let program = (dict?["Program"] as? String)
                        ?? (dict?["ProgramArguments"] as? [String])?.first
                        ?? ""
                    out.append(LaunchItem(label: label, program: program, plistURL: url,
                                          scope: scope, enabled: enabled))
                }
            } catch {
                diagnostics.noteSkipped(dir, error)
            }
        }
        read(userDir, scope: .user, enabled: true)
        read(disabledDir, scope: .user, enabled: false)
        read(URL(fileURLWithPath: "/Library/LaunchAgents"), scope: .global, enabled: true)
        read(URL(fileURLWithPath: "/Library/LaunchDaemons"), scope: .daemon, enabled: true)
        diagnostics.finish()
        return LoginItemsScanResult(items: out, diagnostics: diagnostics)
    }
}

private struct LoginItemsScanResult {
    var items: [LaunchItem]
    var diagnostics: ScanDiagnostics
}
