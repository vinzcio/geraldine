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

enum TaskStatus: Hashable { case idle, running, done, failed }

struct MaintenanceRun: Equatable {
    let ok: Bool
    let command: String
    let output: String
    let finishedAt: Date
}

struct MaintenanceCommandResult: Equatable, Sendable {
    let ok: Bool
    let output: String
    let finishedAt: Date
}

protocol MaintenanceCommandRunning: Sendable {
    func run(_ launchPath: String, arguments: [String]) async -> MaintenanceCommandResult
    func runAdmin(_ command: String) async -> MaintenanceCommandResult
}

struct LiveMaintenanceCommandRunner: MaintenanceCommandRunning {
    func run(_ launchPath: String, arguments: [String]) async -> MaintenanceCommandResult {
        await Task.detached {
            let result = Shell.run(launchPath, arguments)
            return MaintenanceCommandResult(
                ok: result.status == 0,
                output: result.output,
                finishedAt: result.finishedAt
            )
        }.value
    }

    func runAdmin(_ command: String) async -> MaintenanceCommandResult {
        await Task.detached {
            let result = Shell.runAdmin(command)
            return MaintenanceCommandResult(
                ok: result.ok,
                output: result.output,
                finishedAt: result.finishedAt
            )
        }.value
    }
}

protocol MaintenanceClock: Sendable {
    func waitForIdleRevert() async
}

struct SystemMaintenanceClock: MaintenanceClock {
    func waitForIdleRevert() async {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
    }
}

@MainActor
final class MaintenanceViewModel: ObservableObject {
    @Published var status: [String: TaskStatus] = [:]
    @Published var lastRuns: [String: MaintenanceRun] = [:]

    private let runner: any MaintenanceCommandRunning
    private let clock: any MaintenanceClock

    let tasks: [MaintenanceTask]

    init(
        runner: any MaintenanceCommandRunning = LiveMaintenanceCommandRunner(),
        clock: any MaintenanceClock = SystemMaintenanceClock()
    ) {
        self.runner = runner
        self.clock = clock
        self.tasks = Self.defaultTasks
    }

    private static let defaultTasks: [MaintenanceTask] = [
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
            let result: MaintenanceCommandResult
            if task.needsAdmin {
                result = await runner.runAdmin(task.command)
            } else {
                result = await runner.run("/bin/sh", arguments: ["-c", task.command])
            }
            let run = MaintenanceRun(
                ok: result.ok,
                command: task.command,
                output: result.output,
                finishedAt: result.finishedAt
            )
            self.lastRuns[task.id] = run
            self.status[task.id] = run.ok ? .done : .failed
            if run.ok { self.scheduleIdleRevert(task.id) }
        }
    }

    /// A successful task shows .done briefly, then returns to .idle so its button
    /// stays tappable. lastRuns is left intact so the completion time still reads.
    private func scheduleIdleRevert(_ id: String) {
        Task {
            await resetSuccessfulStateAfterDelay(id)
        }
    }

    func resetSuccessfulStateAfterDelay(_ id: String) async {
        await clock.waitForIdleRevert()
        if status[id] == .done { status[id] = .idle }
    }
}
