import SwiftUI

struct MaintenanceTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let needsAdmin: Bool
    let command: String
}

enum TaskStatus: Equatable { case idle, running, done, failed }

@MainActor
final class MaintenanceViewModel: ObservableObject {
    @Published var status: [String: TaskStatus] = [:]

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
              command: "mdutil -E / >/dev/null"),
        .init(id: "launchservices", title: "Rebuild \u{201C}Open With\u{201D} Menu",
              detail: "Clears duplicate app entries in the Open With menu.",
              icon: "square.and.arrow.up.on.square", needsAdmin: false,
              command: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user")
    ]

    func status(_ id: String) -> TaskStatus { status[id] ?? .idle }

    func run(_ task: MaintenanceTask) {
        status[task.id] = .running
        Task {
            let ok = await Task.detached { () -> Bool in
                if task.needsAdmin { return Shell.runAdmin(task.command).ok }
                return Shell.run("/bin/sh", ["-c", task.command]).status == 0
            }.value
            self.status[task.id] = ok ? .done : .failed
        }
    }
}
