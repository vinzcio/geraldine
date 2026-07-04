import SwiftUI

struct MaintenanceTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let needsAdmin: Bool
    let command: String

    var confirmationMessage: String {
        switch id {
        case "dns":
            return "This restarts DNS cache services. Existing network activity may briefly pause."
        case "purge":
            return "This asks macOS to release cached memory and purgeable disk space. Apps may feel slower while caches rebuild."
        case "periodic":
            return "This runs macOS daily, weekly, and monthly maintenance scripts now. It can take several minutes."
        case "spotlight":
            return "This erases and rebuilds the Spotlight index for the startup volume. Search results may be incomplete until indexing finishes."
        case "launchservices":
            return "This rebuilds the Open With application registry. Finder and app launch menus may refresh while it runs."
        default:
            return detail
        }
    }
}

enum TaskStatus: Equatable { case idle, running, done, failed }

struct MaintenanceRun: Equatable {
    let ok: Bool
    let command: String
    let output: String
    let finishedAt: Date
}

@MainActor
final class MaintenanceViewModel: ObservableObject {
    @Published var status: [String: TaskStatus] = [:]
    @Published var lastRuns: [String: MaintenanceRun] = [:]

    let tasks: [MaintenanceTask] = [
        .init(id: "dns", title: "Flush DNS Cache",
              detail: "Fixes sites that won't load after a network change.",
              icon: "globe", needsAdmin: true,
              command: "dscacheutil -flushcache; killall -HUP mDNSResponder"),
        .init(id: "purge", title: "Free Purgeable Space",
              detail: "Releases cached memory and disk that macOS is holding.",
              icon: "internaldrive", needsAdmin: true,
              command: "/usr/sbin/purge"),
        .init(id: "periodic", title: "Run Maintenance Scripts",
              detail: "Runs macOS's built-in daily, weekly and monthly upkeep.",
              icon: "calendar", needsAdmin: true,
              command: "periodic daily weekly monthly"),
        .init(id: "spotlight", title: "Rebuild Spotlight Index",
              detail: "Fixes search when results are missing or wrong.",
              icon: "magnifyingglass", needsAdmin: true,
              command: "mdutil -E /"),
        .init(id: "launchservices", title: "Rebuild \u{201C}Open With\u{201D} Menu",
              detail: "Clears duplicate app entries in the Open With menu.",
              icon: "square.and.arrow.up.on.square", needsAdmin: false,
              command: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user")
    ]

    func status(_ id: String) -> TaskStatus { status[id] ?? .idle }
    func lastRun(_ id: String) -> MaintenanceRun? { lastRuns[id] }

    func run(_ task: MaintenanceTask) {
        status[task.id] = .running
        Task {
            let run = await Task.detached { () -> MaintenanceRun in
                if task.needsAdmin {
                    let result = Shell.runAdmin(task.command)
                    return MaintenanceRun(ok: result.ok,
                                          command: task.command,
                                          output: result.output,
                                          finishedAt: result.finishedAt)
                }
                let result = Shell.run("/bin/sh", ["-c", task.command])
                return MaintenanceRun(ok: result.status == 0,
                                      command: task.command,
                                      output: result.output,
                                      finishedAt: result.finishedAt)
            }.value
            self.lastRuns[task.id] = run
            self.status[task.id] = run.ok ? .done : .failed
        }
    }
}
