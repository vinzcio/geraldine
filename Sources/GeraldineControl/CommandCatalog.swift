import Foundation

public struct CommandArgument: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var required: Bool
    public var description: String

    public init(name: String, type: String, required: Bool, description: String) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
    }
}

public struct CommandDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var summary: String
    public var usage: String
    public var subcommands: [String]
    public var arguments: [CommandArgument]
    public var needsRunningApp: Bool
    public var sideEffects: [String]

    public init(
        name: String,
        summary: String,
        usage: String,
        subcommands: [String] = [],
        arguments: [CommandArgument] = [],
        needsRunningApp: Bool = true,
        sideEffects: [String] = []
    ) {
        self.name = name
        self.summary = summary
        self.usage = usage
        self.subcommands = subcommands
        self.arguments = arguments
        self.needsRunningApp = needsRunningApp
        self.sideEffects = sideEffects
    }
}

public enum CommandCatalog {
    public static let version = "0.1.0"

    public static let commands: [CommandDefinition] = [
        CommandDefinition(
            name: "status",
            summary: "Show app, Keep Awake, Stay Active, assertions, and live vitals.",
            usage: "geraldine status [--json]",
            sideEffects: []
        ),
        CommandDefinition(
            name: "awake",
            summary: "Turn Keep Awake on, off, or toggle it.",
            usage: "geraldine awake on [--for 90m | --indefinitely] | off | toggle [--json]",
            subcommands: ["on", "off", "toggle"],
            sideEffects: ["Creates or releases IOPM power assertions."]
        ),
        CommandDefinition(
            name: "stay-active",
            summary: "Turn idle activity simulation on or off, or change its delay.",
            usage: "geraldine stay-active on|off | stay-active delay <1|2|5> [--json]",
            subcommands: ["on", "off", "delay"],
            sideEffects: ["Starts or stops synthetic input pulses while Keep Awake is active."]
        ),
        CommandDefinition(
            name: "settings",
            summary: "List, read, or change a whitelisted setting live.",
            usage: "geraldine settings list | get <key> | set <key> <value> [--json]",
            subcommands: ["list", "get", "set"],
            sideEffects: ["Changes apply immediately and persist to the app's preferences."]
        ),
        CommandDefinition(
            name: "widgets",
            summary: "Inspect or edit the popover widget layout.",
            usage: "geraldine widgets list|show|hide|size|move|reset [--json]",
            subcommands: ["list", "show", "hide", "size", "move", "reset"],
            sideEffects: ["Changes the popover layout and the live menu-bar metric."]
        ),
        CommandDefinition(
            name: "stats",
            summary: "Read one live metric or all of them, optionally watching.",
            usage: "geraldine stats [cpu|memory|gpu|network|battery|thermal|storage|all] [--watch] [--json]",
            arguments: [
                CommandArgument(name: "metric", type: "enum", required: false, description: "cpu, memory, gpu, network, battery, thermal, storage, or all")
            ],
            sideEffects: []
        ),
        CommandDefinition(
            name: "processes",
            summary: "Show the busiest processes by CPU or memory.",
            usage: "geraldine processes [--top N] [--sort cpu|memory] [--json]",
            sideEffects: []
        ),
        CommandDefinition(
            name: "usage",
            summary: "Show coding-assistant remaining usage and reset windows.",
            usage: "geraldine usage [--refresh] [--json]",
            sideEffects: ["--refresh makes the providers' own CLIs re-read their local usage caches."]
        ),
        CommandDefinition(
            name: "devices",
            summary: "List external drives, iOS devices, and Bluetooth peripherals.",
            usage: "geraldine devices [--json]",
            sideEffects: []
        ),
        CommandDefinition(
            name: "permissions",
            summary: "Report Full Disk Access, Accessibility, Screen Recording, and location.",
            usage: "geraldine permissions [--json]",
            sideEffects: []
        ),
        CommandDefinition(
            name: "open",
            summary: "Navigate the main window to a page.",
            usage: "geraldine open [page] [--json]",
            arguments: [
                CommandArgument(name: "page", type: "enum", required: false, description: "A module name such as dashboard, keepAwake, settings, or activity")
            ],
            sideEffects: ["Shows and focuses the main window."]
        ),
        CommandDefinition(
            name: "doctor",
            summary: "Check the CLI, socket, permissions, launch-at-login, and Keep Awake invariants.",
            usage: "geraldine doctor [--json]",
            sideEffects: []
        ),
        CommandDefinition(
            name: "cleanup",
            summary: "Scan caches, logs, Trash, and old installers without deleting anything.",
            usage: "geraldine cleanup scan [--json]",
            subcommands: ["scan"],
            sideEffects: ["Reads user folders; never deletes."]
        ),
        CommandDefinition(
            name: "large-files",
            summary: "Find large and old files without moving them.",
            usage: "geraldine large-files scan [--path DIR] [--min-size MB] [--json]",
            subcommands: ["scan"],
            sideEffects: ["Reads the selected folder; never deletes."]
        ),
        CommandDefinition(
            name: "storage",
            summary: "Measure storage categories on the startup volume.",
            usage: "geraldine storage scan [--json]",
            subcommands: ["scan"],
            sideEffects: ["Reads folder sizes; never deletes."]
        ),
        CommandDefinition(
            name: "smart-care",
            summary: "Run the Smart Care health scan without queuing actions.",
            usage: "geraldine smart-care scan [--json]",
            subcommands: ["scan"],
            sideEffects: ["Reads disk and memory state; never changes anything."]
        ),
        CommandDefinition(
            name: "privacy",
            summary: "Scan browser caches, cookies, and history without deleting them.",
            usage: "geraldine privacy scan [--json]",
            subcommands: ["scan"],
            sideEffects: ["Reads browser data sizes; never deletes."]
        ),
        CommandDefinition(
            name: "uninstaller",
            summary: "List installed applications and their sizes.",
            usage: "geraldine uninstaller list [--json]",
            subcommands: ["list"],
            sideEffects: ["Reads application bundles; never uninstalls."]
        ),
        CommandDefinition(
            name: "login-items",
            summary: "List launch agents and daemons without changing them.",
            usage: "geraldine login-items list [--json]",
            subcommands: ["list"],
            sideEffects: ["Reads property lists; never changes launchd state."]
        ),
        CommandDefinition(
            name: "commands",
            summary: "Print the machine-readable command catalog.",
            usage: "geraldine commands [--json]",
            needsRunningApp: false,
            sideEffects: []
        ),
        CommandDefinition(
            name: "install-cli",
            summary: "Copy this executable into a directory on PATH.",
            usage: "geraldine install-cli [--dir DIR] [--json]",
            needsRunningApp: false,
            sideEffects: ["Writes one executable file in the destination directory."]
        ),
        CommandDefinition(
            name: "help",
            summary: "Show the command overview or help for one command.",
            usage: "geraldine help [command]",
            needsRunningApp: false,
            sideEffects: []
        )
    ]

    public static func command(named name: String) -> CommandDefinition? {
        commands.first { $0.name == name }
    }

    public static var jsonValue: JSONValue {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(commands),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return .array([])
        }
        return JSONValue.from(object)
    }
}
