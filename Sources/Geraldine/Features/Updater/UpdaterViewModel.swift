import SwiftUI
import AppKit

struct OutdatedApp: Identifiable, Hashable {
    let id = UUID()
    let token: String
    let name: String
    let current: String
    let latest: String
}

@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published var loading = false
    @Published var brewPath: String?
    @Published var outdated: [OutdatedApp] = []
    @Published var upgrading: Set<String> = []
    @Published var checked = false

    var hasBrew: Bool { brewPath != nil }

    func load() {
        loading = true
        Task {
            let path = await Task.detached { Shell.which("brew") }.value
            self.brewPath = path
            if let path {
                self.outdated = await Self.fetchOutdated(brew: path)
            }
            self.loading = false
            self.checked = true
        }
    }

    func upgrade(_ app: OutdatedApp) {
        guard let brew = brewPath else { return }
        upgrading.insert(app.token)
        Task {
            let ok = await Task.detached {
                Shell.run(brew, ["upgrade", "--cask", app.token]).status == 0
            }.value
            self.upgrading.remove(app.token)
            if ok { self.outdated.removeAll { $0.token == app.token } }
        }
    }

    func copyInstallCommand() {
        let cmd = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    private static func fetchOutdated(brew: String) async -> [OutdatedApp] {
        await Task.detached(priority: .userInitiated) { () -> [OutdatedApp] in
            let r = Shell.run(brew, ["outdated", "--cask", "--json=v2"])
            guard r.status == 0, let data = r.output.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let casks = root["casks"] as? [[String: Any]] else { return [] }
            return casks.compactMap { entry in
                guard let token = entry["name"] as? String else { return nil }
                let current = (entry["installed_versions"] as? [String])?.last ?? "—"
                let latest = (entry["current_version"] as? String) ?? "—"
                let display = token.replacingOccurrences(of: "-", with: " ").capitalized
                return OutdatedApp(token: token, name: display, current: current, latest: latest)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }
}
