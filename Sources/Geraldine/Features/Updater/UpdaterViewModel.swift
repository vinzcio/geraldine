import SwiftUI
import AppKit

struct OutdatedApp: Identifiable, Hashable {
    let token: String
    let name: String
    let current: String
    let latest: String
    let applicationURL: URL?

    var id: String { token }
}

enum BrewCheckState: Equatable {
    case unchecked
    case unavailable(checkedAt: Date)
    case failed(message: String, output: String, checkedAt: Date)
    case noUpdates(checkedAt: Date)
    case updatesAvailable(checkedAt: Date)
}

enum UpdaterDisplayPhase: Hashable {
    case unchecked
    case checking
    case unavailable
    case failed
    case noUpdates
    case updatesAvailable
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
    @Published var completed: [OutdatedApp] = []
    @Published var checked = false
    @Published var checkState: BrewCheckState = .unchecked

    var hasBrew: Bool { brewPath != nil }
    var displayPhase: UpdaterDisplayPhase {
        if loading { return .checking }
        switch checkState {
        case .unchecked: return .unchecked
        case .unavailable: return .unavailable
        case .failed: return .failed
        case .noUpdates: return .noUpdates
        case .updatesAvailable: return .updatesAvailable
        }
    }

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
        completed = []
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
                self.completed.removeAll { $0.token == app.token }
                self.completed.append(app)
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
            let fallbackName = token.replacingOccurrences(of: "-", with: " ").capitalized
            let applicationURL = installedApplicationURL(token: token, fallbackName: fallbackName)
            let displayName = applicationURL.flatMap(applicationDisplayName) ?? fallbackName
            return OutdatedApp(token: token,
                               name: displayName,
                               current: current,
                               latest: latest,
                               applicationURL: applicationURL)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return UpdaterCheckReport(
            brewPath: brew,
            outdated: apps,
            state: apps.isEmpty ? .noUpdates(checkedAt: result.finishedAt)
                                : .updatesAvailable(checkedAt: result.finishedAt)
        )
    }

    private nonisolated static func installedApplicationURL(token: String, fallbackName: String) -> URL? {
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true), homeApplications]
        let names = [fallbackName, token, token.replacingOccurrences(of: "-", with: " ")]

        for root in roots {
            for name in names {
                let candidate = root.appendingPathComponent(name).appendingPathExtension("app")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    private nonisolated static func applicationDisplayName(_ url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }
}

private struct UpdaterCheckReport {
    var brewPath: String?
    var outdated: [OutdatedApp]
    var state: BrewCheckState
}
