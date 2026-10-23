import Foundation
import Darwin

public struct CommandLineIO: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void
    public var isTTY: Bool

    public init(
        out: @escaping @Sendable (String) -> Void,
        err: @escaping @Sendable (String) -> Void,
        isTTY: Bool
    ) {
        self.out = out
        self.err = err
        self.isTTY = isTTY
    }

    public static let standard = CommandLineIO(
        out: { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        },
        err: { text in
            FileHandle.standardError.write(Data(text.utf8))
        },
        isTTY: isatty(STDOUT_FILENO) == 1
    )
}

public struct DoctorCheck: Codable, Equatable, Sendable {
    public var name: String
    public var status: String
    public var detail: String

    public init(name: String, status: String, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

public enum GeraldinePages {
    public static let all = [
        "dashboard", "smartCare", "activity", "codingUsage", "storage", "battery",
        "keepAwake", "calendar", "cleanup", "largeFiles", "uninstaller",
        "powerTools", "privacy", "loginItems", "maintenance", "updater",
        "permissions", "settings"
    ]
}

public enum GeraldineCommandLine {
    private struct GlobalOptions {
        var json = false
        var socketURL = ControlEndpoint.socketURL()
        var timeout: TimeInterval = 120
        var launch = false
        var help = false
        var version = false
        var arguments: [String] = []
    }

    public static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        io: CommandLineIO = .standard
    ) -> Int32 {
        let global = parseGlobal(arguments: Array(arguments.dropFirst()), environment: environment)
        if global.version {
            writeLine("geraldine \(CommandCatalog.version) (protocol \(ControlProtocol.version), schema \(ControlProtocol.schemaVersion))", io: io)
            return 0
        }
        guard let first = global.arguments.first else {
            writeLine(overview, io: io)
            return global.help ? 0 : 2
        }

        if first == "help" {
            let topic = global.arguments.dropFirst().first
            writeLine(topic.map(help(for:)) ?? overview, io: io)
            return 0
        }
        if global.help {
            writeLine(help(for: first), io: io)
            return 0
        }

        let rest = Array(global.arguments.dropFirst())
        switch first {
        case "commands":
            return runCommands(json: global.json, io: io)
        case "install-cli":
            return runInstallCLI(arguments: rest, json: global.json, io: io)
        case "settings":
            return runSettings(arguments: rest, global: global, io: io)
        case "doctor":
            return runDoctor(rest: rest, global: global, io: io)
        default:
            return runRemote(first: first, rest: rest, global: global, io: io)
        }
    }

    // MARK: - Global parsing

    private static func parseGlobal(arguments: [String], environment: [String: String]) -> GlobalOptions {
        var global = GlobalOptions(socketURL: ControlEndpoint.socketURL(environment: environment))
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                global.json = true
            case "--launch":
                global.launch = true
            case "--help", "-h":
                global.help = true
            case "--version", "-v":
                global.version = true
            case "--no-color":
                break
            case "--socket":
                if index + 1 < arguments.count {
                    index += 1
                    global.socketURL = URL(fileURLWithPath: arguments[index])
                }
            case "--timeout":
                if index + 1 < arguments.count, let value = Double(arguments[index + 1]), value > 0 {
                    index += 1
                    global.timeout = value
                }
            default:
                if argument.hasPrefix("--socket=") {
                    global.socketURL = URL(fileURLWithPath: String(argument.dropFirst("--socket=".count)))
                } else if argument.hasPrefix("--timeout="), let value = Double(argument.dropFirst("--timeout=".count)), value > 0 {
                    global.timeout = value
                } else {
                    global.arguments.append(argument)
                }
            }
            index += 1
        }
        return global
    }

    // MARK: - Remote dispatch

    private static func runRemote(first: String, rest: [String], global: GlobalOptions, io: CommandLineIO) -> Int32 {
        guard let definition = CommandCatalog.command(named: first) else {
            return fail(
                command: first,
                code: .usage,
                message: "Unknown command \"\(first)\".",
                hint: "Run `geraldine --help` or `geraldine commands --json`.",
                json: global.json,
                io: io
            )
        }
        guard !definition.readOnlyUnavailable else {
            return fail(command: first, code: .usage, message: "\(first) is not a control command.", hint: nil, json: global.json, io: io)
        }

        var requestArguments: [String] = []
        var options: [String: String] = [:]

        switch first {
        case "awake":
            guard let sub = rest.first, ["on", "off", "toggle"].contains(sub) else {
                return usageFailure(command: first, hint: "Use `geraldine awake on|off|toggle`.", json: global.json, io: io)
            }
            requestArguments = [sub]
            var index = 1
            while index < rest.count {
                let argument = rest[index]
                switch argument {
                case "--indefinitely", "--forever":
                    options["duration"] = "indefinitely"
                case "--for":
                    guard index + 1 < rest.count else {
                        return usageFailure(command: first, hint: "--for needs a duration such as 90m.", json: global.json, io: io)
                    }
                    index += 1
                    do {
                        let duration = try DurationParser.parse(rest[index])
                        options["duration"] = try encodeDuration(duration)
                    } catch {
                        return usageFailure(command: first, hint: error.localizedDescription, json: global.json, io: io)
                    }
                default:
                    if argument.hasPrefix("--for=") {
                        do {
                            let duration = try DurationParser.parse(String(argument.dropFirst("--for=".count)))
                            options["duration"] = try encodeDuration(duration)
                        } catch {
                            return usageFailure(command: first, hint: error.localizedDescription, json: global.json, io: io)
                        }
                    } else {
                        return usageFailure(command: first, hint: "Unknown awake option \"\(argument)\".", json: global.json, io: io)
                    }
                }
                index += 1
            }
            if sub == "off", options["duration"] != nil {
                return usageFailure(command: first, hint: "awake off does not take a duration.", json: global.json, io: io)
            }

        case "stay-active":
            guard let sub = rest.first else {
                return usageFailure(command: first, hint: "Use `geraldine stay-active on|off` or `stay-active delay 2`.", json: global.json, io: io)
            }
            if sub == "delay" {
                guard rest.count == 2, let minutes = Int(rest[1]), [1, 2, 5].contains(minutes) else {
                    return usageFailure(command: first, hint: "stay-active delay needs 1, 2, or 5 minutes.", json: global.json, io: io)
                }
                requestArguments = [sub, String(minutes)]
            } else if ["on", "off"].contains(sub), rest.count == 1 {
                requestArguments = [sub]
            } else {
                return usageFailure(command: first, hint: "Use `geraldine stay-active on|off` or `stay-active delay 2`.", json: global.json, io: io)
            }

        case "widgets":
            guard let sub = rest.first else {
                return usageFailure(command: first, hint: "Use `geraldine widgets list|show|hide|size|move|reset`.", json: global.json, io: io)
            }
            switch sub {
            case "list", "reset":
                guard rest.count == 1 else {
                    return usageFailure(command: first, hint: "widgets \(sub) takes no arguments.", json: global.json, io: io)
                }
                requestArguments = [sub]
            case "show", "hide":
                guard rest.count == 2 else {
                    return usageFailure(command: first, hint: "widgets \(sub) needs a widget id.", json: global.json, io: io)
                }
                requestArguments = [sub, rest[1]]
            case "size":
                guard rest.count == 3, ["small", "medium", "large"].contains(rest[2]) else {
                    return usageFailure(command: first, hint: "widgets size needs a widget id and small|medium|large.", json: global.json, io: io)
                }
                requestArguments = [sub, rest[1], rest[2]]
            case "move":
                guard rest.count >= 2 else {
                    return usageFailure(command: first, hint: "widgets move needs a widget id.", json: global.json, io: io)
                }
                requestArguments = ["move", rest[1]]
                let extra = Array(rest.dropFirst(2))
                if extra.isEmpty || extra == ["--front"] {
                    options["position"] = "front"
                } else if extra.count == 2, extra[0] == "--before" {
                    options["position"] = "before"
                    options["before"] = extra[1]
                } else {
                    return usageFailure(command: first, hint: "Use `widgets move <id> [--front | --before <id>]`.", json: global.json, io: io)
                }
            default:
                return usageFailure(command: first, hint: "Unknown widgets subcommand \"\(sub)\".", json: global.json, io: io)
            }

        case "stats":
            let metric = rest.first(where: { !$0.hasPrefix("--") }) ?? "all"
            guard ["cpu", "memory", "gpu", "network", "battery", "thermal", "storage", "all"].contains(metric) else {
                return usageFailure(command: first, hint: "Unknown metric \"\(metric)\".", json: global.json, io: io)
            }
            requestArguments = [metric]
            if rest.contains("--watch") { options["watch"] = "true" }

        case "processes":
            var index = 0
            while index < rest.count {
                switch rest[index] {
                case "--top":
                    guard index + 1 < rest.count, let value = Int(rest[index + 1]), value > 0, value <= 200 else {
                        return usageFailure(command: first, hint: "--top needs a number from 1 to 200.", json: global.json, io: io)
                    }
                    options["top"] = String(value)
                    index += 2
                case "--sort":
                    guard index + 1 < rest.count, ["cpu", "memory"].contains(rest[index + 1]) else {
                        return usageFailure(command: first, hint: "--sort needs cpu or memory.", json: global.json, io: io)
                    }
                    options["sort"] = rest[index + 1]
                    index += 2
                default:
                    return usageFailure(command: first, hint: "Unknown processes option \"\(rest[index])\".", json: global.json, io: io)
                }
            }

        case "usage":
            if rest.contains("--refresh") { options["refresh"] = "true" }

        case "permissions", "devices":
            guard rest.isEmpty else {
                return usageFailure(command: first, hint: "\(first) takes no arguments.", json: global.json, io: io)
            }

        case "open":
            if let page = rest.first {
                guard GeraldinePages.all.contains(page) else {
                    return usageFailure(
                        command: first,
                        hint: "Unknown page \"\(page)\". Try one of: \(GeraldinePages.all.joined(separator: ", ")).",
                        json: global.json,
                        io: io
                    )
                }
                requestArguments = [page]
            }

        case "cleanup", "storage", "smart-care", "privacy":
            guard rest == ["scan"] else {
                return usageFailure(command: first, hint: "Use `geraldine \(first) scan`.", json: global.json, io: io)
            }
            requestArguments = ["scan"]

        case "large-files":
            guard rest.first == "scan" else {
                return usageFailure(command: first, hint: "Use `geraldine large-files scan`.", json: global.json, io: io)
            }
            requestArguments = ["scan"]
            var index = 1
            while index < rest.count {
                switch rest[index] {
                case "--path":
                    guard index + 1 < rest.count else {
                        return usageFailure(command: first, hint: "--path needs a directory.", json: global.json, io: io)
                    }
                    options["path"] = rest[index + 1]
                    index += 2
                case "--min-size":
                    guard index + 1 < rest.count, let value = Int(rest[index + 1]), value > 0 else {
                        return usageFailure(command: first, hint: "--min-size needs a positive number of megabytes.", json: global.json, io: io)
                    }
                    options["minSizeMB"] = String(value)
                    index += 2
                default:
                    return usageFailure(command: first, hint: "Unknown large-files option \"\(rest[index])\".", json: global.json, io: io)
                }
            }

        case "uninstaller", "login-items":
            guard rest == ["list"] else {
                return usageFailure(command: first, hint: "Use `geraldine \(first) list`.", json: global.json, io: io)
            }
            requestArguments = ["list"]

        default:
            guard rest.isEmpty else {
                return usageFailure(command: first, hint: "\(first) takes no arguments.", json: global.json, io: io)
            }
        }

        if first == "stats", options["watch"] == "true", !global.json, !io.isTTY {
            options["watch"] = nil
            emitWarning("--watch needs a TTY; emitting one sample instead.", json: false, io: io)
        }

        if options["watch"] == "true" {
            return watch(command: first, arguments: requestArguments, global: global, io: io)
        }
        return performRemote(command: first, arguments: requestArguments, options: options, global: global, io: io)
    }

    private static func encodeDuration(_ duration: AwakeDuration) throws -> String {
        switch duration {
        case .indefinite:
            return "indefinitely"
        case .seconds(let seconds):
            return String(Int(seconds.rounded()))
        }
    }

    private static func parseDurationOption(_ raw: String) -> AwakeDuration? {
        if raw == "indefinitely" { return .indefinite }
        return Double(raw).map { .seconds($0) }
    }

    // MARK: - Requests

    private static func performRemote(
        command: String,
        arguments: [String],
        options: [String: String],
        global: GlobalOptions,
        io: CommandLineIO
    ) -> Int32 {
        let request = ControlRequest(command: command, arguments: arguments, options: options)
        let client = ControlClient(socketURL: global.socketURL)
        do {
            let response = try client.send(request, timeout: global.timeout)
            return emit(response, json: global.json, io: io)
        } catch {
            return handleUnavailable(command: command, arguments: arguments, options: options, global: global, error: error, io: io)
        }
    }

    private static func watch(
        command: String,
        arguments: [String],
        global: GlobalOptions,
        io: CommandLineIO
    ) -> Int32 {
        let client = ControlClient(socketURL: global.socketURL)
        var first = true
        while true {
            let request = ControlRequest(command: command, arguments: arguments, options: [:])
            do {
                let response = try client.send(request, timeout: global.timeout)
                if global.json {
                    let line = response.encodedLine()
                    if response.ok {
                        io.out(line)
                        io.out("\n")
                    } else {
                        io.err(line)
                        io.err("\n")
                    }
                } else {
                    if !first { io.out("\n") }
                    emitHuman(response, io: io)
                }
                first = false
                if !response.ok { return response.exitCode }
            } catch {
                return handleUnavailable(
                    command: command,
                    arguments: arguments,
                    options: [:],
                    global: global,
                    error: error,
                    io: io
                )
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private static func handleUnavailable(
        command: String,
        arguments: [String],
        options: [String: String],
        global: GlobalOptions,
        error: Error,
        io: CommandLineIO
    ) -> Int32 {
        let running = ProcessLookup.isRunning()

        if command == "settings" {
            return runSettingsLocally(arguments: arguments, appRunning: running, json: global.json, io: io)
        }
        if command == "doctor" {
            return runLocalDoctor(global: global, io: io, appError: error)
        }

        if global.launch, !running {
            launchApp()
            Thread.sleep(forTimeInterval: 2)
            let request = ControlRequest(command: command, arguments: arguments, options: options)
            if let response = try? ControlClient(socketURL: global.socketURL).send(request, timeout: global.timeout) {
                return emit(response, json: global.json, io: io)
            }
        }

        if command == "awake", running {
            return awakeURLFallback(arguments: arguments, options: options, global: global, io: io)
        }

        let message: String
        let hint: String
        if running {
            message = "Geraldine is running, but its control socket is unavailable."
            hint = "This build may predate the command line. Rebuild or restart Geraldine, then try again."
        } else {
            message = "Geraldine is not running."
            hint = "Open Geraldine, or rerun with --launch."
        }
        return fail(command: command, code: .notRunning, message: message, hint: hint, json: global.json, io: io)
    }

    private static func awakeURLFallback(
        arguments: [String],
        options: [String: String],
        global: GlobalOptions,
        io: CommandLineIO
    ) -> Int32 {
        guard let sub = arguments.first else {
            return usageFailure(command: "awake", hint: "Use awake on|off|toggle.", json: global.json, io: io)
        }
        var url = "geraldine:\(sub == "off" ? "deactivate" : sub == "toggle" ? "toggle" : "activate")"
        if sub != "off", let raw = options["duration"], let duration = parseDurationOption(raw) {
            switch duration {
            case .indefinite:
                url += "?duration=indefinitely"
            case .seconds(let seconds):
                url += "?minutes=\(String(format: "%.4f", seconds / 60))"
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return fail(
                    command: "awake",
                    code: .failed,
                    message: "The URL fallback could not reach Geraldine.",
                    hint: "Open Geraldine and try again.",
                    json: global.json,
                    io: io
                )
            }
        } catch {
            return fail(
                command: "awake",
                code: .failed,
                message: "Could not run the URL fallback: \(error.localizedDescription)",
                hint: nil,
                json: global.json,
                io: io
            )
        }

        let response = ControlResponse(
            command: "awake",
            ok: true,
            text: [
                "Sent the request through Geraldine's URL handler.",
                "This build has no control socket, so the result could not be confirmed."
            ],
            result: .object(["method": .string("url"), "url": .string(url)]),
            warnings: ["No control socket; the URL fallback cannot report the resulting state."]
        )
        return emit(response, json: global.json, io: io)
    }

    private static func launchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Geraldine"]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Settings

    private static func runSettings(arguments: [String], global: GlobalOptions, io: CommandLineIO) -> Int32 {
        guard let sub = arguments.first else {
            return usageFailure(command: "settings", hint: "Use `geraldine settings list|get|set`.", json: global.json, io: io)
        }
        switch sub {
        case "list":
            guard arguments.count == 1 else {
                return usageFailure(command: "settings", hint: "settings list takes no arguments.", json: global.json, io: io)
            }
            return performRemote(command: "settings", arguments: ["list"], options: [:], global: global, io: io)

        case "get":
            guard arguments.count == 2, SettingsCatalog.definition(for: arguments[1]) != nil else {
                return usageFailure(command: "settings", hint: "settings get needs a known key; run `geraldine settings list`.", json: global.json, io: io)
            }
            return performRemote(command: "settings", arguments: ["get", arguments[1]], options: [:], global: global, io: io)

        case "set":
            guard arguments.count >= 3,
                  let definition = SettingsCatalog.definition(for: arguments[1]) else {
                return usageFailure(command: "settings", hint: "settings set needs a known key and a value.", json: global.json, io: io)
            }
            guard !definition.readOnly else {
                return usageFailure(command: "settings", hint: "\"\(definition.key)\" is read-only.", json: global.json, io: io)
            }
            let raw = arguments.dropFirst(2).joined(separator: " ")
            do {
                _ = try SettingsCatalog.parse(raw, for: definition)
            } catch {
                return usageFailure(command: "settings", hint: error.localizedDescription, json: global.json, io: io)
            }
            return performRemote(
                command: "settings",
                arguments: ["set", definition.key, raw],
                options: [:],
                global: global,
                io: io
            )

        default:
            return usageFailure(command: "settings", hint: "Unknown settings subcommand \"\(sub)\".", json: global.json, io: io)
        }
    }

    private static func runSettingsLocally(
        arguments: [String],
        appRunning: Bool,
        json: Bool,
        io: CommandLineIO
    ) -> Int32 {
        let reader = SettingsReader(appRunning: appRunning)
        let note = appRunning
            ? "Geraldine is running, but its control socket is unavailable. Showing saved preferences."
            : "Geraldine is not running. Showing saved preferences; changes need the app."

        if arguments.first == "get" {
            guard arguments.count == 2, let definition = SettingsCatalog.definition(for: arguments[1]) else {
                return usageFailure(command: "settings", hint: "settings get needs a known key; run `geraldine settings list`.", json: json, io: io)
            }
            let value = reader.value(for: definition)
            let response = ControlResponse(
                command: "settings",
                ok: true,
                text: ["\(definition.key) = \(value?.displayString ?? "(app is required)")", note],
                result: .object([
                    "appRunning": .bool(appRunning),
                    "key": .string(definition.key),
                    "value": value ?? .null,
                    "requiresRunningApp": .bool(definition.requiresRunningApp)
                ])
            )
            return emit(response, json: json, io: io)
        }

        if arguments.first == "set" {
            return fail(
                command: "settings",
                code: .notRunning,
                message: appRunning
                    ? "Geraldine is running, but its control socket is unavailable."
                    : "Geraldine is not running.",
                hint: "Changes need the app; run `geraldine settings list` to read saved values.",
                json: json,
                io: io
            )
        }
        guard arguments == ["list"] else {
            return usageFailure(command: "settings", hint: "Use `geraldine settings list|get|set`.", json: json, io: io)
        }
        let snapshot = reader.snapshot()
        var lines = [note]
        var resultSettings: [String: JSONValue] = [:]
        for definition in SettingsCatalog.definitions {
            let value = snapshot[definition.key]
            resultSettings[definition.key] = value ?? .null
            lines.append("\(definition.key) = \(value?.displayString ?? "(app is required)")")
        }
        let response = ControlResponse(
            command: "settings",
            ok: true,
            text: lines,
            result: .object([
                "appRunning": .bool(appRunning),
                "settings": .object(resultSettings)
            ])
        )
        return emit(response, json: json, io: io)
    }

    // MARK: - Doctor

    private static func runDoctor(rest: [String], global: GlobalOptions, io: CommandLineIO) -> Int32 {
        guard rest.isEmpty else {
            return usageFailure(command: "doctor", hint: "doctor takes no arguments.", json: global.json, io: io)
        }
        let request = ControlRequest(command: "doctor")
        do {
            let response = try ControlClient(socketURL: global.socketURL).send(request, timeout: 10)
            return emit(response, json: global.json, io: io)
        } catch {
            return runLocalDoctor(global: global, io: io, appError: error)
        }
    }

    private static func runLocalDoctor(global: GlobalOptions, io: CommandLineIO, appError: Error?) -> Int32 {
        var checks: [DoctorCheck] = []
        let appRunning = ProcessLookup.isRunning()
        checks.append(DoctorCheck(
            name: "Geraldine",
            status: appRunning ? "ok" : "fail",
            detail: appRunning ? "The app process is running." : "The app process is not running."
        ))

        let socketPath = global.socketURL.path
        var socketStatus = "fail"
        var socketDetail = "No socket at \(socketPath)."
        if let attributes = try? FileManager.default.attributesOfItem(atPath: socketPath) {
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let type = attributes[.type] as? FileAttributeType
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
            if type == .typeSocket, owner == Int(geteuid()) {
                socketStatus = "ok"
                socketDetail = "Socket exists with mode \(String(mode, radix: 8)) and the current owner."
            } else {
                socketDetail = "A file exists but is not an owned socket (mode \(String(mode, radix: 8)))."
            }
        }
        if appRunning, socketStatus != "ok" { socketStatus = "fail" }
        if !appRunning, socketStatus != "ok" { socketStatus = "warn" }
        checks.append(DoctorCheck(name: "Control socket", status: socketStatus, detail: socketDetail))

        if let appError, appRunning {
            checks.append(DoctorCheck(name: "Control handshake", status: "fail", detail: appError.localizedDescription))
        }

        let helper = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/geraldine")
        let helperInstalled = FileManager.default.isExecutableFile(atPath: helper.path)
        checks.append(DoctorCheck(
            name: "CLI on PATH",
            status: helperInstalled ? "ok" : "warn",
            detail: helperInstalled
                ? "Found \(helper.path)."
                : "Not installed at \(helper.path). Run `geraldine install-cli`."
        ))

        let result = JSONValue.object([
            "appRunning": .bool(appRunning),
            "checks": .array(checks.map { check in
                .object([
                    "name": .string(check.name),
                    "status": .string(check.status),
                    "detail": .string(check.detail)
                ])
            })
        ])
        let text = checks.map { check in
            "[\(check.status.uppercased())] \(check.name): \(check.detail)"
        }
        let controlReady = appRunning && socketStatus == "ok"
        let response = ControlResponse(
            command: "doctor",
            ok: controlReady,
            text: text,
            result: result,
            error: controlReady
                ? nil
                : ControlErrorPayload(
                    code: .notRunning,
                    message: appRunning
                        ? "Geraldine is running but the control socket is not ready."
                        : "Geraldine is not running.",
                    hint: appRunning
                        ? "Reopen Geraldine from a build that includes the command line."
                        : "Open Geraldine, or rerun with --launch."
                )
        )
        let exit: Int32 = controlReady ? 0 : 3
        if global.json {
            let line = response.encodedLine()
            if controlReady { io.out(line) } else { io.err(line) }
        } else {
            emitHuman(response, io: io)
        }
        return exit
    }

    // MARK: - Catalog / install

    private static func runCommands(json: Bool, io: CommandLineIO) -> Int32 {
        let result = JSONValue.object([
            "schemaVersion": .int(ControlProtocol.schemaVersion),
            "protocolVersion": .int(ControlProtocol.version),
            "commands": CommandCatalog.jsonValue
        ])
        let lines = CommandCatalog.commands.map { command in
            let app = command.needsRunningApp ? "app" : "local"
            return "\(command.name)  [\(app)]  \(command.summary)"
        }
        let response = ControlResponse(command: "commands", ok: true, text: lines, result: result)
        return emit(response, json: json, io: io)
    }

    private static func runInstallCLI(arguments: [String], json: Bool, io: CommandLineIO) -> Int32 {
        var destinationDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--dir", index + 1 < arguments.count {
                var path = arguments[index + 1]
                if path == "~" {
                    path = FileManager.default.homeDirectoryForCurrentUser.path
                } else if path.hasPrefix("~/") {
                    path = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(String(path.dropFirst(2))).path
                }
                destinationDirectory = URL(fileURLWithPath: path, isDirectory: true)
                index += 2
            } else {
                return usageFailure(command: "install-cli", hint: "Use `geraldine install-cli [--dir DIR]`.", json: json, io: io)
            }
        }

        guard let source = currentExecutable() else {
            return fail(command: "install-cli", code: .failed, message: "Could not locate the running geraldine executable.", hint: nil, json: json, io: io)
        }
        let destination = destinationDirectory.appendingPathComponent("geraldine")
        do {
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            try data.write(to: destination, options: .atomic)
            _ = chmod(destination.path, 0o755)
        } catch {
            return fail(
                command: "install-cli",
                code: .failed,
                message: "Could not install the CLI at \(destination.path): \(error.localizedDescription)",
                hint: "Choose a writable directory with --dir.",
                json: json,
                io: io
            )
        }

        let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .contains { $0 == destinationDirectory.path }
        let response = ControlResponse(
            command: "install-cli",
            ok: true,
            text: [
                "Installed geraldine at \(destination.path).",
                onPath
                    ? "The directory is already on PATH."
                    : "Add \(destinationDirectory.path) to PATH to run `geraldine` from anywhere."
            ],
            result: .object([
                "installed": .bool(true),
                "path": .string(destination.path),
                "source": .string(source.path),
                "onPath": .bool(onPath)
            ])
        )
        return emit(response, json: json, io: io)
    }

    private static func currentExecutable() -> URL? {
        let first = ProcessInfo.processInfo.arguments.first ?? ""
        if first.contains("/") {
            return URL(fileURLWithPath: first).resolvingSymlinksInPath()
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(first)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath()
            }
        }
        return nil
    }

    // MARK: - Output

    @discardableResult
    private static func emit(_ response: ControlResponse, json: Bool, io: CommandLineIO) -> Int32 {
        if json {
            let line = response.encodedLine()
            if response.ok {
                io.out(line)
            } else {
                io.err(line)
            }
        } else {
            emitHuman(response, io: io)
        }
        return response.exitCode
    }

    private static func emitHuman(_ response: ControlResponse, io: CommandLineIO) {
        if let text = response.text, !text.isEmpty {
            for line in text { writeLine(line, io: io) }
        } else if let result = response.result, let rendered = JSONValue.encodeLine(result) {
            writeLine(rendered, io: io)
        }
        for warning in response.warnings {
            writeLine("warning: \(warning)", to: io.err)
        }
        if !response.ok, let error = response.error {
            writeLine("error: \(error.message)", to: io.err)
            if let hint = error.hint { writeLine("hint: \(hint)", to: io.err) }
        }
    }

    private static func emitWarning(_ message: String, json: Bool, io: CommandLineIO) {
        if !json { writeLine("warning: \(message)", to: io.err) }
    }

    private static func fail(
        command: String,
        code: ControlErrorCode,
        message: String,
        hint: String?,
        json: Bool,
        io: CommandLineIO
    ) -> Int32 {
        let response = ControlResponse.localFailure(command: command, code: code, message: message, hint: hint)
        return emit(response, json: json, io: io)
    }

    private static func usageFailure(command: String, hint: String?, json: Bool, io: CommandLineIO) -> Int32 {
        let usage = CommandCatalog.command(named: command).map { "usage: \($0.usage)" }
        let response = ControlResponse(
            command: command,
            ok: false,
            text: usage.map { [$0] },
            error: ControlErrorPayload(code: .usage, message: hint ?? "Invalid command arguments.", hint: usage)
        )
        return emit(response, json: json, io: io)
    }

    private static func writeLine(_ text: String, io: CommandLineIO) {
        io.out(text)
        io.out("\n")
    }

    private static func writeLine(_ text: String, to sink: @Sendable (String) -> Void) {
        sink(text)
        sink("\n")
    }

    // MARK: - Help

    private static let overview = """
    geraldine \(CommandCatalog.version) — control Geraldine from the terminal

    USAGE
      geraldine [--json] [--socket PATH] <command> [arguments]

    CORE
      status                     App, Keep Awake, assertions, and vitals
      awake on|off|toggle        Keep Awake control
      stay-active on|off|delay   Idle activity simulation
      settings list|get|set      Typed, live, persisted settings
      widgets list|show|hide|size|move|reset
                                 Popover and menu-bar layout
      stats [metric]             Live metrics, optional --watch
      processes --top N --sort   Busiest processes
      usage [--refresh]          Coding-assistant allowances
      devices | permissions      Hardware and access readiness
      open [page]                Navigate the main window
      doctor                     Diagnose the CLI and app

    READ-ONLY SCANS
      cleanup scan | large-files scan | storage scan
      smart-care scan | privacy scan | uninstaller list | login-items list

    MORE
      commands --json            Machine-readable command catalog
      install-cli [--dir DIR]    Copy the CLI into ~/.local/bin
      geraldine <command> --help

    Every command supports --json. Exit codes: 0 ok, 1 failed, 2 usage,
    3 app not running, 4 permission missing.
    """

    private static func help(for name: String) -> String {
        guard let definition = CommandCatalog.command(named: name) else {
            return "Unknown command \"\(name)\".\n\n\(overview)"
        }
        var lines = [
            "geraldine \(definition.name)",
            "",
            definition.summary,
            "",
            "USAGE",
            "  \(definition.usage)",
            "",
            "NEEDS",
            "  \(definition.needsRunningApp ? "Geraldine running" : "No app required")"
        ]
        if !definition.subcommands.isEmpty {
            lines.append("")
            lines.append("SUBCOMMANDS")
            lines.append("  \(definition.subcommands.joined(separator: " | "))")
        }
        if !definition.arguments.isEmpty {
            lines.append("")
            lines.append("ARGUMENTS")
            for argument in definition.arguments {
                lines.append("  \(argument.name) (\(argument.type))\(argument.required ? "" : ", optional"): \(argument.description)")
            }
        }
        if !definition.sideEffects.isEmpty {
            lines.append("")
            lines.append("SIDE EFFECTS")
            for effect in definition.sideEffects { lines.append("  - \(effect)") }
        }
        lines.append("")
        lines.append("Add --json for a stable machine-readable envelope.")
        return lines.joined(separator: "\n")
    }
}

private extension CommandDefinition {
    /// Commands whose definition exists for discoverability but which are
    /// resolved locally or need special handling.
    var readOnlyUnavailable: Bool {
        name == "commands" || name == "install-cli" || name == "help"
    }
}
