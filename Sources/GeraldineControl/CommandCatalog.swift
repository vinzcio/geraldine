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

    private static let globalArguments: [CommandArgument] = [
        CommandArgument(name: "--json", type: "boolean", required: false, description: "Emit one schemaVersion 1 envelope per result; errors go to stderr."),
        CommandArgument(name: "--socket", type: "path", required: false, description: "Socket path (value required). Explicit endpoints never launch or fall back to the installed app."),
        CommandArgument(name: "--timeout", type: "number", required: false, description: "Finite positive seconds for an entire request, including launch/retry. No implicit deadline; watch applies this to each sample request."),
        CommandArgument(name: "--launch", type: "boolean", required: false, description: "For app requests on the default endpoint, ask macOS to launch a closed app and retry once immediately. Readiness must be confirmed; local commands need no launch."),
        CommandArgument(name: "--help", type: "boolean", required: false, description: "Show overview or command help without executing an action; alias -h."),
        CommandArgument(name: "--version", type: "boolean", required: false, description: "Show helper/protocol/schema versions with no command or action arguments; alias -v."),
        CommandArgument(name: "--no-color", type: "boolean", required: false, description: "Accepted for scripts; output contains no ANSI color.")
    ]

    public static let commands: [CommandDefinition] = [
        CommandDefinition(
            name: "status",
            summary: "Show app, Keep Awake, Stay Active, assertions, and live vitals.",
            usage: "geraldine [status] [--json]",
            sideEffects: []
        ),
        CommandDefinition(
            name: "awake",
            summary: "Turn Keep Awake on, off, or toggle it.",
            usage: "geraldine awake on [--for 90m | --indefinitely] | off | toggle [--json]",
            subcommands: ["on", "off", "toggle"],
            arguments: [
                CommandArgument(name: "action", type: "enum", required: true, description: "on, off, or toggle"),
                CommandArgument(name: "--for", type: "duration", required: false, description: "Duration for on/toggle, such as 90m or 1h30m. Finite positive seconds round up to the app's whole-second representation."),
                CommandArgument(name: "--indefinitely", type: "boolean", required: false, description: "Use no expiry for on/toggle; alias --forever.")
            ],
            sideEffects: ["Creates or releases IOPM power assertions."]
        ),
        CommandDefinition(
            name: "stay-active",
            summary: "Turn idle activity simulation on or off, or change its delay.",
            usage: "geraldine stay-active on|off | stay-active delay <1|2|5> [--json]",
            subcommands: ["on", "off", "delay"],
            arguments: [
                CommandArgument(name: "action", type: "enum", required: true, description: "on, off, or delay"),
                CommandArgument(name: "minutes", type: "integer", required: false, description: "Required after delay: 1, 2, or 5, matching the app's existing choices.")
            ],
            sideEffects: ["Starts or stops synthetic input pulses while Keep Awake is active."]
        ),
        CommandDefinition(
            name: "settings",
            summary: "List/read saved settings offline on the default endpoint; changes and virtual settings need the running app.",
            usage: "geraldine settings list | get <key> | set <key> <value> [--json]",
            subcommands: ["list", "get", "set"],
            arguments: [
                CommandArgument(name: "action", type: "enum", required: true, description: "list, get, or set. list/get can read saved preferences without the app; explicit endpoints disable this fallback."),
                CommandArgument(name: "key", type: "string", required: false, description: "Required for get/set; a key from the settings catalog."),
                CommandArgument(name: "value", type: "typed value", required: false, description: "Required for set; boolean, integer, enumeration, string, or JSON according to the setting definition.")
            ],
            sideEffects: ["set applies immediately through the running app and persists to its preferences; list/get never write."]
        ),
        CommandDefinition(
            name: "widgets",
            summary: "Inspect or edit the popover widget layout.",
            usage: "geraldine widgets list|show|hide|size|move|reset [--json]",
            subcommands: ["list", "show", "hide", "size", "move", "reset"],
            arguments: [
                CommandArgument(name: "action", type: "enum", required: true, description: "list, show, hide, size, move, or reset"),
                CommandArgument(name: "id", type: "string", required: false, description: "Required for show/hide/size/move; an id returned by widgets list."),
                CommandArgument(name: "size", type: "enum", required: false, description: "Required after widgets size <id>: small, medium, or large."),
                CommandArgument(name: "--front", type: "boolean", required: false, description: "For move, place the widget first (also the existing default)."),
                CommandArgument(name: "--before", type: "string", required: false, description: "For move, the following widget id is required; mutually exclusive with --front.")
            ],
            sideEffects: ["Changes the popover layout and the live menu-bar metric."]
        ),
        CommandDefinition(
            name: "stats",
            summary: "Read one live metric or all of them, optionally watching.",
            usage: "geraldine stats [cpu|memory|gpu|network|battery|thermal|storage|all] [--watch <seconds>] [--json]",
            arguments: [
                CommandArgument(name: "metric", type: "enum", required: false, description: "cpu, memory, gpu, network, battery, thermal, storage, or all (default all)"),
                CommandArgument(name: "--watch", type: "number", required: false, description: "Finite positive interval in seconds required when supplied; repeat cached samples with one JSON envelope per line.")
            ],
            sideEffects: []
        ),
        CommandDefinition(
            name: "processes",
            summary: "Show the busiest processes by CPU or memory.",
            usage: "geraldine processes [--top N] [--sort cpu|memory] [--json]",
            arguments: [
                CommandArgument(name: "--top", type: "integer", required: false, description: "Positive count (default 10), with an overflow-safe doubled app sampling count."),
                CommandArgument(name: "--sort", type: "enum", required: false, description: "cpu (default) or memory; value required when supplied.")
            ],
            sideEffects: []
        ),
        CommandDefinition(
            name: "usage",
            summary: "Show coding-assistant remaining usage and reset windows.",
            usage: "geraldine usage [--refresh] [--json]",
            arguments: [CommandArgument(name: "--refresh", type: "boolean", required: false, description: "Refresh enabled accounts in the background and return cached values immediately.")],
            sideEffects: ["--refresh runs enabled accounts' official provider CLIs using existing sign-ins; those CLIs may contact their providers and update local usage caches. Geraldine issues no usage HTTP requests and reads no Keychain."]
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
                CommandArgument(name: "page", type: "enum", required: false, description: GeraldinePages.all.joined(separator: ", "))
            ],
            sideEffects: ["Shows and focuses the main window."]
        ),
        CommandDefinition(
            name: "doctor",
            summary: "Check installed app presence, PATH, CLI/app identity, socket handshake, permissions, and Keep Awake. Offline diagnostics report unavailable control.",
            usage: "geraldine doctor [--json]",
            sideEffects: []
        ),
        CommandDefinition(
            name: "cleanup",
            summary: "Scan caches, logs, Trash, and old installers without deleting anything.",
            usage: "geraldine cleanup scan [--json]",
            subcommands: ["scan"],
            arguments: [CommandArgument(name: "action", type: "enum", required: true, description: "scan (read-only)")],
            sideEffects: ["Reads user folders; never deletes."]
        ),
        CommandDefinition(
            name: "large-files",
            summary: "Find large and old files without moving them.",
            usage: "geraldine large-files scan [--path DIR] [--min-size MB] [--json]",
            subcommands: ["scan"],
            arguments: [
                CommandArgument(name: "action", type: "enum", required: true, description: "scan (read-only)"),
                CommandArgument(name: "--path", type: "path", required: false, description: "Folder to scan (value required); otherwise the existing app scanner's selected/default folder."),
                CommandArgument(name: "--min-size", type: "integer", required: false, description: "Positive decimal megabytes representable as UInt64 bytes; the app scanner's existing minimum applies when omitted.")
            ],
            sideEffects: ["Reads the selected folder; never deletes."]
        ),
        CommandDefinition(
            name: "storage",
            summary: "Measure storage categories on the startup volume.",
            usage: "geraldine storage scan [--json]",
            subcommands: ["scan"],
            arguments: [CommandArgument(name: "action", type: "enum", required: true, description: "scan (read-only)")],
            sideEffects: ["Reads folder sizes; never deletes."]
        ),
        CommandDefinition(
            name: "smart-care",
            summary: "Run the Smart Care health scan without queuing actions.",
            usage: "geraldine smart-care scan [--json]",
            subcommands: ["scan"],
            arguments: [CommandArgument(name: "action", type: "enum", required: true, description: "scan (read-only)")],
            sideEffects: ["Reads disk and memory state; never changes anything."]
        ),
        CommandDefinition(
            name: "privacy",
            summary: "Scan browser caches, cookies, and history without deleting them.",
            usage: "geraldine privacy scan [--json]",
            subcommands: ["scan"],
            arguments: [CommandArgument(name: "action", type: "enum", required: true, description: "scan (read-only)")],
            sideEffects: ["Reads browser data sizes; never deletes."]
        ),
        CommandDefinition(
            name: "uninstaller",
            summary: "List installed applications and their sizes.",
            usage: "geraldine uninstaller list [--json]",
            subcommands: ["list"],
            arguments: [CommandArgument(name: "action", type: "enum", required: true, description: "list (read-only)")],
            sideEffects: ["Reads application bundles; never uninstalls."]
        ),
        CommandDefinition(
            name: "login-items",
            summary: "List launch agents and daemons without changing them.",
            usage: "geraldine login-items list [--json]",
            subcommands: ["list"],
            arguments: [CommandArgument(name: "action", type: "enum", required: true, description: "list (read-only)")],
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
            summary: "Symlink this helper into a directory on PATH.",
            usage: "geraldine install-cli [--dir DIR] [--json]",
            arguments: [CommandArgument(name: "--dir", type: "path", required: false, description: "Installation directory (value required), default ~/.local/bin; creates a symlink to this resolved helper.")],
            needsRunningApp: false,
            sideEffects: ["Creates or updates a Geraldine helper symlink; preserves unrelated destinations."]
        ),
        CommandDefinition(
            name: "help",
            summary: "Show the command overview or help for one command.",
            usage: "geraldine help [command] [--json]",
            arguments: [CommandArgument(name: "command", type: "enum", required: false, description: "A command name from this catalog; omitted for the overview.")],
            needsRunningApp: false,
            sideEffects: []
        )
    ].map { definition in
        var command = definition
        command.arguments += globalArguments
        return command
    }

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
