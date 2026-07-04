import SwiftUI
import AppKit

struct OutdatedApp: Identifiable, Hashable {
    let id = UUID()
    let token: String
    let name: String
    let current: String
    let latest: String
}

enum BrewCheckState: Equatable {
    case unchecked
    case unavailable(checkedAt: Date)
    case failed(message: String, output: String, checkedAt: Date)
    case noUpdates(checkedAt: Date)
    case updatesAvailable(checkedAt: Date)
}

struct BrewCommandFeedback: Equatable {
    let ok: Bool
    let message: String
    let output: String
    let checkedAt: Date
}

@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published var loading = false
    @Published var brewPath: String?
    @Published var outdated: [OutdatedApp] = []
    @Published var upgrading: Set<String> = []
    @Published var upgradeFeedback: [String: BrewCommandFeedback] = [:]
    @Published var checked = false
    @Published var checkState: BrewCheckState = .unchecked

    var hasBrew: Bool { brewPath != nil }
    var checkedAt: Date? {
        switch checkState {
        case .unchecked: return nil
        case .unavailable(let date), .failed(_, _, let date), .noUpdates(let date), .updatesAvailable(let date):
            return date
        }
    }

    func load() {
        loading = true
        checkState = .unchecked
        upgradeFeedback = [:]
        Task {
            let report = await Task.detached(priority: .userInitiated) { Self.checkForUpdates() }.value
            self.brewPath = report.brewPath
            self.outdated = report.outdated
            self.checkState = report.state
            self.loading = false
            self.checked = true
        }
    }

    func upgrade(_ app: OutdatedApp) {
        guard let brew = brewPath else { return }
        upgrading.insert(app.token)
        upgradeFeedback[app.token] = nil
        Task {
            let feedback = await Task.detached { () -> BrewCommandFeedback in
                let result = Shell.run(brew, ["upgrade", "--cask", app.token])
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = result.status == 0
                return BrewCommandFeedback(
                    ok: ok,
                    message: ok ? "Updated \(app.name)." : "Homebrew could not update \(app.name).",
                    output: output,
                    checkedAt: result.finishedAt
                )
            }.value
            self.upgrading.remove(app.token)
            self.upgradeFeedback[app.token] = feedback
            if feedback.ok {
                self.outdated.removeAll { $0.token == app.token }
                if self.outdated.isEmpty {
                    self.checkState = .noUpdates(checkedAt: feedback.checkedAt)
                }
            }
        }
    }

    func copyInstallCommand() {
        let cmd = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    private nonisolated static func checkForUpdates() -> UpdaterCheckReport {
        guard let brew = Shell.which("brew") else {
            return UpdaterCheckReport(brewPath: nil,
                                      outdated: [],
                                      state: .unavailable(checkedAt: Date()))
        }

        let result = Shell.run(brew, ["outdated", "--cask", "--json=v2"])
        guard result.status == 0 else {
            return UpdaterCheckReport(
                brewPath: brew,
                outdated: [],
                state: .failed(message: "Homebrew outdated check failed with exit code \(result.status).",
                               output: result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                               checkedAt: result.finishedAt)
            )
        }

        guard let data = result.output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else {
            return UpdaterCheckReport(
                brewPath: brew,
                outdated: [],
                state: .failed(message: "Homebrew returned output Geraldine could not read.",
                               output: result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                               checkedAt: result.finishedAt)
            )
        }

        let apps: [OutdatedApp] = casks.compactMap { (entry: [String: Any]) -> OutdatedApp? in
            guard let token = entry["name"] as? String else { return nil }
            let current = (entry["installed_versions"] as? [String])?.last ?? "-"
            let latest = (entry["current_version"] as? String) ?? "-"
            let display = token.replacingOccurrences(of: "-", with: " ").capitalized
            return OutdatedApp(token: token, name: display, current: current, latest: latest)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return UpdaterCheckReport(
            brewPath: brew,
            outdated: apps,
            state: apps.isEmpty ? .noUpdates(checkedAt: result.finishedAt)
                                : .updatesAvailable(checkedAt: result.finishedAt)
        )
    }
}

private struct UpdaterCheckReport {
    var brewPath: String?
    var outdated: [OutdatedApp]
    var state: BrewCheckState
}
