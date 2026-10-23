import AppKit
import Combine
import Foundation
import GeraldineControl
import IOKit.pwr_mgt

/// The app-side endpoint for `geraldine`. It owns one Unix-domain socket, answers
/// newline-JSON requests on the main actor, and touches only existing controllers.
/// Starting the server is best-effort: a failed bind must never stop the app.
@MainActor
final class ControlHost {
    static let shared = ControlHost()

    private var server: ControlServer?
    private var usageWaiter: UsageRefreshWaiter?
    private(set) var startupError: String?

    var socketPath: String {
        server?.socketURL.path ?? ControlEndpoint.socketURL().path
    }

    var isRunning: Bool { server?.isRunning == true }

    // MARK: - Lifecycle

    func start() {
        guard server == nil else { return }
        let server = ControlServer { [weak self] request in
            guard let self else {
                return ControlResponse.localFailure(
                    command: request.command,
                    code: .failed,
                    message: "Geraldine's control host is unavailable.",
                    hint: "Reopen Geraldine."
                )
            }
            return await self.handle(request)
        }
        do {
            try server.start()
            self.server = server
            startupError = nil
        } catch {
            startupError = error.localizedDescription
            NSLog("Geraldine control socket unavailable: %@", error.localizedDescription)
        }
    }

    func stop() {
        usageWaiter?.cancel()
        usageWaiter = nil
        server?.stop()
        server = nil
    }

    // MARK: - Dispatch

    private func handle(_ request: ControlRequest) async -> ControlResponse {
        switch request.command {
        case "status":
            return status(request)
        case "awake":
            return awake(request)
        case "stay-active":
            return stayActive(request)
        case "settings":
            return settings(request)
        case "widgets":
            return widgets(request)
        case "stats":
            return stats(request)
        case "processes":
            return await processes(request)
        case "usage":
            return await usage(request)
        case "devices":
            return devices(request)
        case "permissions":
            return permissions(request)
        case "open":
            return open(request)
        case "doctor":
            return doctor(request)
        case "cleanup":
            return await cleanup(request)
        case "large-files":
            return await largeFiles(request)
        case "storage":
            return await storage(request)
        case "smart-care":
            return await smartCare(request)
        case "privacy":
            return await privacy(request)
        case "uninstaller":
            return await uninstaller(request)
        case "login-items":
            return await loginItems(request)
        default:
            return ControlResponse.failure(
                for: request,
                code: .usage,
                message: "Unknown control command \"\(request.command)\".",
                hint: "Run `geraldine commands --json` for the catalog."
            )
        }
    }

    // MARK: - Status

    private func status(_ request: ControlRequest) -> ControlResponse {
        let state = AppState.shared
        let keepAwake = state.keepAwake
        let assertions = PowerAssertionSnapshot.current()
        let build = BuildInfo.current

        var keepAwakeJSON: [String: JSONValue] = [
            "active": .bool(keepAwake.isActive),
            "paused": .bool(keepAwake.isPaused),
            "statusLine": .string(keepAwake.statusLine),
            "endTimeLine": .string(keepAwake.endTimeLine),
            "defaultDuration": .string(keepAwake.defaultDuration.rawValue),
            "allowDisplaySleep": .bool(keepAwake.allowDisplaySleep),
            "deactivateOnBattery": .bool(keepAwake.deactivateOnBattery),
            "pauseWhenScreenLocked": .bool(keepAwake.pauseWhenScreenLocked),
            "idleActivityStatusLine": .string(keepAwake.idleActivityStatusLine),
            "remainingSeconds": ControlJSON.optionalNumber(keepAwake.remaining),
            "activeUntil": ControlJSON.date(keepAwake.activeUntil),
            "progressFraction": ControlJSON.optionalNumber(keepAwake.progressFraction)
        ]
        keepAwakeJSON["pauseReason"] = keepAwake.pauseReason.map { .string($0) } ?? .null
        keepAwakeJSON["lastError"] = keepAwake.lastError.map { .string($0) } ?? .null
        keepAwakeJSON["assertions"] = assertions.json

        let result = JSONValue.object([
            "app": .object([
                "name": .string("Geraldine"),
                "version": .string(build.version),
                "build": .string(build.bundleVersion),
                "configuration": .string(build.configuration),
                "pid": .int(Int(getpid())),
                "appShape": .string(state.appShape.rawValue),
                "launchAtLogin": .bool(LaunchAtLogin.isEnabled),
                "socket": .string(socketPath),
                "fullDiskAccess": .bool(state.hasFullDiskAccess),
                "accessibility": .bool(state.hasAccessibility)
            ]),
            "keepAwake": .object(keepAwakeJSON),
            "stayActive": stayActiveJSON(),
            "vitals": vitalsJSON(includeAll: true)
        ])

        var text = [
            "Geraldine \(build.version) (running, pid \(getpid())) — \(state.appShape.label)",
            "Keep Awake: \(keepAwake.statusLine)"
        ]
        if keepAwake.isActive {
            text.append("            \(keepAwake.endTimeLine)")
        }
        text.append("Stay Active: \(keepAwake.idleActivityStatusLine)")
        text.append(assertions.humanLine)
        text.append(vitalsText(includeAll: true).joined(separator: " · "))
        return ControlResponse.success(for: request, text: text, result: result)
    }

    private func stayActiveJSON() -> JSONValue {
        let keepAwake = AppState.shared.keepAwake
        var object: [String: JSONValue] = [
            "enabled": .bool(keepAwake.simulateIdleActivity),
            "delayMinutes": .int(keepAwake.idleActivityDelayMinutes),
            "phase": .string(phaseName(keepAwake.idleActivityPhase)),
            "needsAccessibility": .bool(keepAwake.idleActivityNeedsAccessibility),
            "statusLine": .string(keepAwake.idleActivityStatusLine),
            "lastPulse": ControlJSON.date(keepAwake.idleActivityLastPulse),
            "lastUserInput": ControlJSON.date(keepAwake.idleActivityLastUserInput)
        ]
        object["error"] = keepAwake.idleActivityError.map { .string($0) } ?? .null
        return .object(object)
    }

    private func phaseName(_ phase: IdleActivitySimulationPhase) -> String {
        switch phase {
        case .off: return "off"
        case .waiting: return "waiting"
        case .pulsing: return "pulsing"
        case .needsAccessibility: return "needsAccessibility"
        case .failed: return "failed"
        }
    }

    // MARK: - Keep Awake

    private func awake(_ request: ControlRequest) -> ControlResponse {
        let keepAwake = AppState.shared.keepAwake
        guard let subcommand = request.arguments.first,
              ["on", "off", "toggle"].contains(subcommand) else {
            return usageFailure(request, hint: "Use `geraldine awake on|off|toggle`.")
        }

        let requestedDuration: TimeInterval?
        if let raw = request.options["duration"] {
            if raw == "indefinitely" {
                requestedDuration = nil
            } else if let seconds = Double(raw), seconds > 0 {
                requestedDuration = seconds
            } else {
                return usageFailure(request, hint: "The duration must be seconds or \"indefinitely\".")
            }
        } else {
            requestedDuration = keepAwake.defaultDuration.seconds
        }

        switch subcommand {
        case "on":
            keepAwake.activate(duration: requestedDuration)
        case "off":
            keepAwake.deactivate()
        default:
            if keepAwake.isActive {
                keepAwake.deactivate()
            } else {
                keepAwake.activate(duration: requestedDuration)
            }
        }

        if let error = keepAwake.lastError, !keepAwake.isActive {
            return ControlResponse.failure(
                for: request,
                code: .failed,
                message: error,
                hint: "Run `geraldine status` for the current policy state.",
                text: ["Keep Awake stayed off: \(error)"]
            )
        }

        let assertions = PowerAssertionSnapshot.current()
        let result = keepAwakeJSON(assertions: assertions)
        var text = ["Keep Awake: \(keepAwake.statusLine)"]
        if keepAwake.isActive { text.append(keepAwake.endTimeLine) }
        text.append(assertions.humanLine)
        return ControlResponse.success(for: request, text: text, result: result)
    }

    private func keepAwakeJSON(assertions: PowerAssertionSnapshot) -> JSONValue {
        let keepAwake = AppState.shared.keepAwake
        var object: [String: JSONValue] = [
            "active": .bool(keepAwake.isActive),
            "paused": .bool(keepAwake.isPaused),
            "statusLine": .string(keepAwake.statusLine),
            "endTimeLine": .string(keepAwake.endTimeLine),
            "remainingSeconds": ControlJSON.optionalNumber(keepAwake.remaining),
            "activeUntil": ControlJSON.date(keepAwake.activeUntil),
            "defaultDuration": .string(keepAwake.defaultDuration.rawValue),
            "assertions": assertions.json
        ]
        object["pauseReason"] = keepAwake.pauseReason.map { .string($0) } ?? .null
        object["lastError"] = keepAwake.lastError.map { .string($0) } ?? .null
        return .object(object)
    }

    private func stayActive(_ request: ControlRequest) -> ControlResponse {
        let keepAwake = AppState.shared.keepAwake
        guard let subcommand = request.arguments.first else {
            return usageFailure(request, hint: "Use `geraldine stay-active on|off` or `stay-active delay 2`.")
        }

        switch subcommand {
        case "on":
            keepAwake.simulateIdleActivity = true
        case "off":
            keepAwake.simulateIdleActivity = false
        case "delay":
            guard request.arguments.count == 2,
                  let minutes = Int(request.arguments[1]),
                  KeepAwakeController.idleActivityDelayOptions.contains(minutes) else {
                return usageFailure(request, hint: "stay-active delay needs 1, 2, or 5 minutes.")
            }
            keepAwake.idleActivityDelayMinutes = minutes
        default:
            return usageFailure(request, hint: "Use `geraldine stay-active on|off` or `stay-active delay 2`.")
        }

        if subcommand == "on" {
            keepAwake.refreshIdleActivityAccess(prompt: false)
        }

        let result = stayActiveJSON()
        if subcommand == "on", keepAwake.idleActivityNeedsAccessibility {
            return ControlResponse(
                id: request.id,
                command: request.command,
                ok: false,
                text: [
                    "Stay Active is enabled, but macOS is blocking synthetic input.",
                    "Grant Accessibility access, then run `geraldine stay-active on` again."
                ],
                result: result,
                error: ControlErrorPayload(
                    code: .permission,
                    message: "Accessibility access is missing, so Stay Active cannot pulse.",
                    hint: "Open System Settings > Privacy & Security > Accessibility and allow Geraldine."
                )
            )
        }

        var text = ["Stay Active: \(keepAwake.idleActivityStatusLine)"]
        if keepAwake.simulateIdleActivity {
            text.append("Delay: \(keepAwake.idleActivityDelayMinutes) minute\(keepAwake.idleActivityDelayMinutes == 1 ? "" : "s") of idle time.")
        }
        return ControlResponse.success(for: request, text: text, result: result)
    }

    // MARK: - Settings and widgets

    private func settings(_ request: ControlRequest) -> ControlResponse {
        guard let subcommand = request.arguments.first else {
            return usageFailure(request, hint: "Use `geraldine settings list|get|set`.")
        }

        switch subcommand {
        case "list":
            let values = ControlSettings.snapshot()
            let constantKeys = ["keepAwake.defaultDuration", "keepAwake.allowDisplaySleep",
                                "appShape", "launchAtLogin"]
            let result = JSONValue.object([
                "appRunning": .bool(true),
                "settings": .object(values),
                "definitions": ControlSettings.definitionsValue()
            ])
            var text = ["Live settings from the running app."]
            for definition in SettingsCatalog.definitions {
                if constantKeys.contains(definition.key) || definition.readOnly {
                    // keep the list in catalog order without another lookup
                }
                text.append("\(definition.key) = \(values[definition.key]?.displayString ?? "null")")
            }
            return ControlResponse.success(for: request, text: text, result: result)

        case "get":
            guard request.arguments.count == 2,
                  let definition = SettingsCatalog.definition(for: request.arguments[1]) else {
                return usageFailure(request, hint: "settings get needs a known key; run `geraldine settings list`.")
            }
            let value = ControlSettings.value(for: definition)
            let result = JSONValue.object([
                "key": .string(definition.key),
                "value": value,
                "kind": .string(definition.kind.rawValue),
                "options": .array(definition.options.map { .string($0) }),
                "requiresRunningApp": .bool(definition.requiresRunningApp),
                "readOnly": .bool(definition.readOnly)
            ])
            return ControlResponse.success(
                for: request,
                text: ["\(definition.key) = \(value.displayString)"],
                result: result
            )

        case "set":
            guard request.arguments.count >= 3 else {
                return usageFailure(request, hint: "settings set needs a known key and a value.")
            }
            let key = request.arguments[1]
            let raw = request.arguments.dropFirst(2).joined(separator: " ")
            do {
                let change = try ControlSettings.set(key: key, rawValue: raw)
                let result = JSONValue.object([
                    "key": .string(key),
                    "previousValue": change.previous,
                    "value": change.current,
                    "changed": .bool(change.previous != change.current)
                ])
                return ControlResponse.success(
                    for: request,
                    text: [
                        "\(key): \(change.previous.displayString) → \(change.current.displayString)",
                        "Applied live and saved."
                    ],
                    result: result
                )
            } catch let error as ControlSettingsError {
                switch error {
                case .readOnly:
                    return ControlResponse.failure(
                        for: request, code: .usage,
                        message: error.localizedDescription,
                        hint: "Read-only settings cannot be changed."
                    )
                case .unknownKey:
                    return usageFailure(request, hint: error.localizedDescription)
                case .invalidValue(_, let message):
                    return ControlResponse.failure(
                        for: request, code: .usage,
                        message: message,
                        hint: "Run `geraldine settings list` for allowed values."
                    )
                case .failed(let message):
                    return ControlResponse.failure(
                        for: request, code: .failed,
                        message: message, hint: nil
                    )
                }
            } catch {
                return ControlResponse.failure(
                    for: request, code: .failed,
                    message: error.localizedDescription, hint: nil
                )
            }

        default:
            return usageFailure(request, hint: "Unknown settings subcommand \"\(subcommand)\".")
        }
    }

    private func widgets(_ request: ControlRequest) -> ControlResponse {
        guard let subcommand = request.arguments.first else {
            return usageFailure(request, hint: "Use `geraldine widgets list|show|hide|size|move|reset`.")
        }
        do {
            let outcome = try ControlSettings.widgetsAction(
                subcommand: subcommand,
                arguments: request.arguments,
                options: request.options
            )
            return ControlResponse.success(for: request, text: outcome.text, result: outcome.result)
        } catch let error as ControlWidgetError {
            return usageFailure(request, hint: error.localizedDescription)
        } catch {
            return ControlResponse.failure(
                for: request, code: .failed,
                message: error.localizedDescription, hint: nil
            )
        }
    }

    // MARK: - Stats

    private func stats(_ request: ControlRequest) -> ControlResponse {
        let metric = request.arguments.first ?? "all"
        let allowed = ["cpu", "memory", "gpu", "network", "battery", "thermal", "storage", "all"]
        guard allowed.contains(metric) else {
            return usageFailure(
                request,
                hint: "Unknown metric \"\(metric)\". Use \(allowed.joined(separator: ", "))."
            )
        }

        let result: JSONValue
        var text: [String]
        if metric == "all" {
            result = vitalsJSON(includeAll: true)
            text = vitalsText(includeAll: true)
        } else {
            result = .object([metric: vitalsJSON(includeAll: false)[metric] ?? .null])
            text = vitalsText(includeAll: false).filter { line in
                line.lowercased().hasPrefix(metricTextPrefix(metric))
            }
            if text.isEmpty { text = [vitalsText(includeAll: false).joined(separator: " · ")] }
        }
        return ControlResponse.success(for: request, text: text, result: result)
    }

    private func metricTextPrefix(_ metric: String) -> String {
        switch metric {
        case "cpu": return "cpu"
        case "memory": return "memory"
        case "gpu": return "gpu"
        case "network": return "network"
        case "battery": return "battery"
        case "thermal": return "temperature"
        case "storage": return "storage"
        default: return metric
        }
    }

    /// Every live metric in one object. `includeAll` is kept explicit so both
    /// `status` and `stats` use exactly the same shapes.
    private func vitalsJSON(includeAll: Bool) -> JSONValue {
        let monitor = AppState.shared.monitor
        var object: [String: JSONValue] = [:]

        object["cpu"] = .object([
            "percent": ControlJSON.number(monitor.cpuUsage * 100),
            "loadAverage1m": ControlJSON.number(monitor.loadAverage)
        ])

        object["memory"] = .object([
            "usedBytes": ControlJSON.bytes(ControlJSON.uint64(monitor.memoryUsed)),
            "totalBytes": ControlJSON.bytes(ControlJSON.uint64(monitor.memoryTotal)),
            "usedPercent": ControlJSON.number(monitor.memoryFraction * 100)
        ])

        let gpuDevices = monitor.gpuHistory.devices.map { device in
            JSONValue.object([
                "id": .string(String(device.id)),
                "name": .string(device.displayName),
                "state": .string(device.state.rawValue),
                "activityPercent": ControlJSON.optionalNumber(device.activity.map { $0 * 100 })
            ])
        }
        var gpuObject: [String: JSONValue] = [
            "devices": .array(gpuDevices),
            "available": .bool(!gpuDevices.isEmpty)
        ]
        gpuObject["selectedID"] = monitor.gpuHistory.selectedDeviceID.map { .string(String($0)) } ?? .null
        object["gpu"] = .object(gpuObject)

        let unit = NetworkRateUnit(rawValue: UserDefaults.standard.string(forKey: "networkRateUnit") ?? "")
            ?? .bytesPerSecond
        object["network"] = .object([
            "downBytesPerSecond": ControlJSON.number(monitor.netDown),
            "upBytesPerSecond": ControlJSON.number(monitor.netUp),
            "unit": .string(unit.rawValue),
            "down": .string(Fmt.rate(monitor.netDown, unit: unit)),
            "up": .string(Fmt.rate(monitor.netUp, unit: unit))
        ])

        var batteryObject: [String: JSONValue] = [
            "hasBattery": .bool(monitor.hasBattery),
            "charging": .bool(monitor.batteryCharging),
            "onAC": .bool(monitor.batteryOnAC),
            "draining": .bool(monitor.batteryDraining),
            "full": .bool(monitor.batteryFull)
        ]
        batteryObject["levelPercent"] = ControlJSON.optionalNumber(monitor.batteryLevel.map { $0 * 100 })
        batteryObject["healthPercent"] = ControlJSON.optionalNumber(monitor.batteryHealth.map { $0 * 100 })
        batteryObject["cycles"] = monitor.batteryCycles.map { .int($0) } ?? .null
        batteryObject["minutesToEmpty"] = monitor.batteryMinutesToEmpty.map { .int($0) } ?? .null
        batteryObject["minutesToFull"] = monitor.batteryMinutesToFull.map { .int($0) } ?? .null
        object["battery"] = .object(batteryObject)

        let thermal = monitor.thermal
        var thermalObject: [String: JSONValue] = [
            "available": .bool(thermal.available),
            "sensorCount": .int(thermal.sensors.count)
        ]
        if thermal.available {
            thermalObject["cpuCelsius"] = ControlJSON.number(thermal.cpu)
            thermalObject["peakCelsius"] = ControlJSON.number(thermal.peak)
            thermalObject["cpuSource"] = .string(thermal.cpuSource)
        } else {
            thermalObject["cpuCelsius"] = .null
            thermalObject["peakCelsius"] = .null
            thermalObject["cpuSource"] = .null
        }
        thermalObject["batteryCelsius"] = ControlJSON.optionalNumber(thermal.battery)
        thermalObject["storageCelsius"] = ControlJSON.optionalNumber(thermal.storage)
        object["thermal"] = .object(thermalObject)

        let diskTotal = monitor.diskTotal
        let diskUsed = monitor.diskUsed
        let diskFree = max(0, diskTotal - diskUsed)
        object["storage"] = .object([
            "totalBytes": ControlJSON.bytes(ControlJSON.uint64(diskTotal)),
            "usedBytes": ControlJSON.bytes(ControlJSON.uint64(diskUsed)),
            "freeBytes": ControlJSON.bytes(ControlJSON.uint64(diskFree)),
            "usedPercent": ControlJSON.number(monitor.diskFraction * 100)
        ])

        if includeAll {
            object["uptimeSeconds"] = ControlJSON.number(monitor.uptime)
        }
        return .object(object)
    }

    private func vitalsText(includeAll: Bool) -> [String] {
        let monitor = AppState.shared.monitor
        var lines: [String] = []
        lines.append("CPU: \(ControlFormat.percent(monitor.cpuUsage))")
        lines.append("Memory: \(ControlFormat.percent(monitor.memoryFraction)) used · \(Fmt.size(monitor.memoryUsed)) of \(Fmt.size(monitor.memoryTotal))")

        if let device = monitor.gpuHistory.selectedDevice {
            if let activity = device.activity {
                lines.append("GPU: \(ControlFormat.percent(activity)) · \(device.displayName)")
            } else {
                lines.append("GPU: \(device.displayName) · \(device.state.rawValue)")
            }
        } else {
            lines.append("GPU: no accelerated device reported")
        }

        let unit = NetworkRateUnit(rawValue: UserDefaults.standard.string(forKey: "networkRateUnit") ?? "")
            ?? .bytesPerSecond
        lines.append("Network: ↓ \(Fmt.rate(monitor.netDown, unit: unit)) · ↑ \(Fmt.rate(monitor.netUp, unit: unit))")

        if monitor.hasBattery, let level = monitor.batteryLevel {
            var battery = "Battery: \(ControlFormat.percent(level))"
            if monitor.batteryCharging { battery += " · charging" }
            else if monitor.batteryOnAC { battery += " · on AC" }
            if let minutes = monitor.batteryMinutesToEmpty, !monitor.batteryCharging {
                battery += " · \(minutes)m remaining"
            }
            if let minutes = monitor.batteryMinutesToFull, monitor.batteryCharging {
                battery += " · \(minutes)m to full"
            }
            lines.append(battery)
        } else {
            lines.append("Battery: no internal battery")
        }

        if monitor.thermal.available {
            lines.append("Temperature: \(String(format: "%.1f", monitor.thermal.cpu))°C · peak \(String(format: "%.1f", monitor.thermal.peak))°C")
        } else {
            lines.append("Temperature: unavailable")
        }

        let diskTotal = monitor.diskTotal
        let diskUsed = monitor.diskUsed
        let diskFree = max(0, diskTotal - diskUsed)
        lines.append("Storage: \(Fmt.size(diskFree)) free of \(Fmt.size(diskTotal)) · \(ControlFormat.percent(monitor.diskFraction)) used")

        if includeAll {
            lines.append("Uptime: \(SystemMonitor.uptimeString(monitor.uptime))")
        }
        return lines
    }

    // MARK: - Processes

    private func processes(_ request: ControlRequest) async -> ControlResponse {
        let top = max(1, min(200, Int(request.options["top"] ?? "") ?? 10))
        let sort = request.options["sort"] == "memory" ? "memory" : "cpu"
        let sampleLimit = max(top * 2, 20)
        let sampled = await Task.detached(priority: .userInitiated) {
            ProcessSampler.sample(limit: sampleLimit)
        }.value

        let sorted = sampled.sorted { lhs, rhs in
            let left = sort == "memory" ? lhs.mem : lhs.cpu
            let right = sort == "memory" ? rhs.mem : rhs.cpu
            return left == right ? lhs.id < rhs.id : left > right
        }
        let rows = Array(sorted.prefix(top))

        let result = JSONValue.object([
            "sort": .string(sort),
            "top": .int(top),
            "processes": .array(rows.map { process in
                .object([
                    "pid": .int(Int(process.id)),
                    "name": .string(process.name),
                    "cpuPercent": ControlJSON.number(process.cpu),
                    "memoryPercent": ControlJSON.number(process.mem),
                    "path": process.executablePath.map { .string($0) } ?? .null
                ])
            })
        ])

        var lines = ["Top \(rows.count) processes by \(sort == "memory" ? "memory" : "CPU"):"]
        for process in rows {
            lines.append(String(
                format: "  %-6d %5.1f%% CPU  %5.1f%% MEM  %@",
                process.id, process.cpu, process.mem, process.name
            ))
        }
        return ControlResponse.success(for: request, text: lines, result: result)
    }

    // MARK: - Coding usage

    private func usage(_ request: ControlRequest) async -> ControlResponse {
        let usage = AppState.shared.aiUsage
        var warnings: [String] = []
        var refreshed = false

        if request.options["refresh"] == "true" {
            usage.refreshConnected()
            let waiter = UsageRefreshWaiter()
            usageWaiter = waiter
            refreshed = await waiter.wait(for: usage, timeout: 25)
            usageWaiter = nil
            if !refreshed {
                warnings.append("The provider refresh is still running; showing the last known values.")
            }
            if usage.accounts.allSatisfy({ !usage.isConnected($0.identity) }) {
                warnings.append("No coding-usage tiles are connected. Show one with `geraldine widgets show ai.claude`.")
            }
        }

        var identities = Set(usage.accounts.map(\.identity))
        identities.formUnion(usage.snapshots.keys)
        let ordered = identities.sorted { $0.id < $1.id }

        let accounts = ordered.map { identity -> JSONValue in
            let snapshot = usage.snapshot(for: identity)
            let status: String
            var error: String?
            switch snapshot.status {
            case .disconnected: status = "disconnected"
            case .needsSignIn: status = "needsSignIn"
            case .loading: status = "loading"
            case .ready: status = "ready"
            case .error(let message): status = "error"; error = message
            }
            var object: [String: JSONValue] = [
                "id": .string(identity.id),
                "provider": .string(identity.provider.rawValue),
                "account": .string(identity.accountKey),
                "displayName": .string(usage.displayName(for: identity)),
                "status": .string(status),
                "windows": .array(snapshot.displayWindows.map { window in
                    .object([
                        "id": .string(window.id),
                        "title": .string(window.title),
                        "usedPercent": ControlJSON.number(window.usedPercent),
                        "remainingPercent": ControlJSON.number(window.remainingPercent),
                        "resetsAt": ControlJSON.date(window.resetsAt),
                        "durationSeconds": ControlJSON.optionalNumber(window.durationSeconds)
                    ])
                })
            ]
            object["plan"] = snapshot.plan.map { .string($0) } ?? .null
            object["fetchedAt"] = ControlJSON.date(snapshot.fetchedAt)
            object["sourceLabel"] = snapshot.sourceLabel.map { .string($0) } ?? .null
            object["accountEmail"] = snapshot.accountEmail.map { .string($0) } ?? .null
            object["error"] = error.map { .string($0) } ?? .null
            return .object(object)
        }

        let result = JSONValue.object([
            "accounts": .array(accounts),
            "refreshed": .bool(refreshed)
        ])

        var lines: [String] = []
        if accounts.isEmpty {
            lines.append("No coding-assistant logins were discovered on this Mac.")
        }
        for identity in ordered {
            let snapshot = usage.snapshot(for: identity)
            let name = usage.displayName(for: identity)
            switch snapshot.status {
            case .disconnected:
                lines.append("\(name): not connected")
            case .needsSignIn:
                lines.append("\(name): sign in with its own CLI to read usage")
            case .loading:
                lines.append("\(name): reading…")
            case .error(let message):
                lines.append("\(name): \(message)")
            case .ready:
                let windows = snapshot.displayWindows.map { window in
                    "\(window.title) \(Int(window.remainingPercent.rounded()))% left"
                }
                lines.append("\(name): " + (windows.isEmpty ? "no quota windows reported" : windows.joined(separator: " · ")))
            }
        }
        if let last = usage.lastRefresh {
            lines.append("Last refreshed \(last.formatted(date: .omitted, time: .shortened)).")
        }
        return ControlResponse.success(for: request, text: lines, result: result, warnings: warnings)
    }

    // MARK: - Devices and permissions

    private func devices(_ request: ControlRequest) -> ControlResponse {
        let monitor = AppState.shared.devices
        let result = JSONValue.object([
            "devices": .array(monitor.devices.map { device in
                .object([
                    "id": .string(device.id),
                    "name": .string(device.name),
                    "kind": .string(kindName(device.kind)),
                    "batteryPercent": ControlJSON.optionalNumber(device.battery.map { $0 * 100 }),
                    "detail": .string(device.detail),
                    "ejectable": .bool(device.ejectable),
                    "path": device.volumeURL.map { .string($0.path) } ?? .null
                ])
            }),
            "scanning": .bool(monitor.scanning)
        ])

        var lines: [String] = []
        if monitor.devices.isEmpty {
            lines.append(monitor.scanning ? "Scanning for connected devices…" : "No external drives, iOS devices, or Bluetooth peripherals.")
        } else {
            for device in monitor.devices {
                var detail = "\(device.name) — \(kindName(device.kind))"
                if let battery = device.battery {
                    detail += " · \(ControlFormat.percent(battery))"
                }
                if !device.detail.isEmpty {
                    detail += " · \(device.detail)"
                }
                lines.append("  \(detail)")
            }
        }
        if monitor.scanning { lines.append("A device scan is still running.") }
        return ControlResponse.success(for: request, text: lines, result: result)
    }

    private func kindName(_ kind: ConnectedDevice.Kind) -> String {
        switch kind {
        case .drive: return "drive"
        case .iosDevice: return "iosDevice"
        case .bluetooth: return "bluetooth"
        }
    }

    private func permissions(_ request: ControlRequest) -> ControlResponse {
        let state = AppState.shared
        state.refreshPermissions()
        let fullDisk = state.hasFullDiskAccess
        let accessibility = state.hasAccessibility
        let screenRecording = Permissions.hasScreenRecordingAccess()
        let location = locationStatus(state.network.nameAccess)

        let result = JSONValue.object([
            "fullDiskAccess": .bool(fullDisk),
            "accessibility": .bool(accessibility),
            "screenRecording": .bool(screenRecording),
            "location": .string(location),
            "requiredReady": .bool(fullDisk && accessibility)
        ])

        var lines = [
            "[\(fullDisk ? "OK" : "MISSING")] Full Disk Access — required for complete scans",
            "[\(accessibility ? "OK" : "MISSING")] Accessibility — required for Stay Active and Power Tools",
            "[\(screenRecording ? "OK" : "OFF")] Screen Recording — optional, Dock window previews",
            "Location — \(location) (optional, only reveals the Wi-Fi name)"
        ]
        if !fullDisk || !accessibility {
            lines.append("Grant access in System Settings > Privacy & Security, then rerun.")
        }
        return ControlResponse.success(for: request, text: lines, result: result)
    }

    private func locationStatus(_ access: NetworkMonitor.NameAccess) -> String {
        switch access {
        case .authorized: return "authorized"
        case .undetermined: return "undetermined"
        case .denied: return "denied"
        }
    }

    // MARK: - Navigation and doctor

    private func open(_ request: ControlRequest) -> ControlResponse {
        let raw = request.arguments.first ?? Module.dashboard.rawValue
        guard let module = Module(rawValue: raw) else {
            return usageFailure(request, hint: "Unknown page \"\(raw)\".")
        }
        AppState.shared.open(module)
        return ControlResponse.success(
            for: request,
            text: ["Opened \(module.title) in the main window."],
            result: .object([
                "page": .string(module.rawValue),
                "title": .string(module.title),
                "window": .string("shown")
            ])
        )
    }

    private func doctor(_ request: ControlRequest) -> ControlResponse {
        let state = AppState.shared
        state.refreshPermissions()
        var checks: [DoctorCheck] = []
        let build = BuildInfo.current

        checks.append(DoctorCheck(
            name: "Geraldine",
            status: "ok",
            detail: "Version \(build.version), pid \(getpid()), answering on the control socket."
        ))

        let path = socketPath
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSocket, owner == Int(geteuid()), mode == 0o600 {
                checks.append(DoctorCheck(name: "Control socket", status: "ok", detail: "Mode 600, owned by the current user at \(path)."))
            } else {
                checks.append(DoctorCheck(name: "Control socket", status: "fail", detail: "Unexpected socket attributes (mode \(String(mode, radix: 8))) at \(path)."))
            }
        } else {
            checks.append(DoctorCheck(name: "Control socket", status: "fail", detail: "The server is answering but \(path) is missing."))
        }

        checks.append(DoctorCheck(
            name: "Full Disk Access",
            status: state.hasFullDiskAccess ? "ok" : "warn",
            detail: state.hasFullDiskAccess ? "Granted." : "Missing; scans may skip protected folders."
        ))
        checks.append(DoctorCheck(
            name: "Accessibility",
            status: state.hasAccessibility ? "ok" : "warn",
            detail: state.hasAccessibility ? "Granted." : "Missing; Stay Active and Power Tools are limited."
        ))
        checks.append(DoctorCheck(
            name: "Launch at login",
            status: "ok",
            detail: LaunchAtLogin.isEnabled ? "Enabled." : "Disabled."
        ))

        let assertions = PowerAssertionSnapshot.current()
        let keepAwake = state.keepAwake
        if assertions.available {
            if keepAwake.isActive && !keepAwake.isPaused {
                var problems: [String] = []
                if !assertions.idleSleep { problems.append("system-sleep assertion is missing") }
                if !keepAwake.allowDisplaySleep && !assertions.displaySleep {
                    problems.append("display-sleep assertion is missing")
                }
                checks.append(DoctorCheck(
                    name: "Keep Awake invariants",
                    status: problems.isEmpty ? "ok" : "fail",
                    detail: problems.isEmpty
                        ? "The active session holds the expected assertions."
                        : problems.joined(separator: "; ") + "."
                ))
            } else {
                checks.append(DoctorCheck(
                    name: "Keep Awake invariants",
                    status: assertions.count == 0 ? "ok" : "fail",
                    detail: assertions.count == 0
                        ? "No session is active and no assertions are held."
                        : "\(assertions.count) assertion(s) are held while Keep Awake is off or paused."
                ))
            }
        } else {
            checks.append(DoctorCheck(
                name: "Keep Awake invariants",
                status: "warn",
                detail: "macOS did not return this process's power assertions."
            ))
        }

        let helper = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/geraldine")
        checks.append(DoctorCheck(
            name: "CLI on PATH",
            status: FileManager.default.isExecutableFile(atPath: helper.path) ? "ok" : "warn",
            detail: FileManager.default.isExecutableFile(atPath: helper.path)
                ? "Found \(helper.path)."
                : "Not installed. Run `geraldine install-cli`."
        ))

        let failed = checks.contains { $0.status == "fail" }
        let result = JSONValue.object([
            "checks": .array(checks.map { check in
                .object([
                    "name": .string(check.name),
                    "status": .string(check.status),
                    "detail": .string(check.detail)
                ])
            }),
            "socket": .string(path)
        ])
        let text = checks.map { check in
            "[\(check.status.uppercased())] \(check.name): \(check.detail)"
        }
        return ControlResponse(
            id: request.id,
            command: request.command,
            ok: !failed,
            text: text,
            result: result,
            error: failed
                ? ControlErrorPayload(
                    code: .failed,
                    message: "One or more doctor checks failed.",
                    hint: "Fix the [FAIL] checks and rerun `geraldine doctor`."
                )
                : nil
        )
    }

    // MARK: - Read-only scans

    private func cleanup(_ request: ControlRequest) async -> ControlResponse {
        guard request.arguments == ["scan"] else {
            return usageFailure(request, hint: "Use `geraldine cleanup scan`.")
        }
        let report = await ControlScans.cleanup()
        return ControlResponse.success(
            for: request,
            text: report.humanLines(title: "Cleanup scan"),
            result: report.json
        )
    }

    private func privacy(_ request: ControlRequest) async -> ControlResponse {
        guard request.arguments == ["scan"] else {
            return usageFailure(request, hint: "Use `geraldine privacy scan`.")
        }
        let report = await ControlScans.privacy()
        return ControlResponse.success(
            for: request,
            text: report.humanLines(title: "Privacy scan"),
            result: report.json
        )
    }

    private func largeFiles(_ request: ControlRequest) async -> ControlResponse {
        guard request.arguments == ["scan"] else {
            return usageFailure(request, hint: "Use `geraldine large-files scan`.")
        }
        let minSize = request.options["minSizeMB"].flatMap(Int.init)
        do {
            let report = try await ControlScans.largeFiles(
                path: request.options["path"],
                minSizeMB: minSize
            )
            return ControlResponse.success(
                for: request,
                text: report.humanLines(title: "Large and old files"),
                result: report.json
            )
        } catch {
            return ControlResponse.failure(
                for: request, code: .usage,
                message: error.localizedDescription,
                hint: "Pass a readable folder with --path."
            )
        }
    }

    private func storage(_ request: ControlRequest) async -> ControlResponse {
        guard request.arguments == ["scan"] else {
            return usageFailure(request, hint: "Use `geraldine storage scan`.")
        }
        do {
            let report = try await ControlScans.storage()
            return ControlResponse.success(
                for: request,
                text: report.humanLines,
                result: report.json
            )
        } catch {
            return ControlResponse.failure(
                for: request, code: .failed,
                message: error.localizedDescription, hint: nil
            )
        }
    }

    private func smartCare(_ request: ControlRequest) async -> ControlResponse {
        guard request.arguments == ["scan"] else {
            return usageFailure(request, hint: "Use `geraldine smart-care scan`.")
        }
        let report = await ControlScans.smartCare()
        return ControlResponse.success(
            for: request,
            text: report.humanLines,
            result: report.json
        )
    }

    private func uninstaller(_ request: ControlRequest) async -> ControlResponse {
        guard request.arguments == ["list"] else {
            return usageFailure(request, hint: "Use `geraldine uninstaller list`.")
        }
        let list = await ControlScans.uninstaller()
        let outcome = ControlScans.appListJSON(list)
        return ControlResponse.success(for: request, text: outcome.text, result: outcome.result)
    }

    private func loginItems(_ request: ControlRequest) async -> ControlResponse {
        guard request.arguments == ["list"] else {
            return usageFailure(request, hint: "Use `geraldine login-items list`.")
        }
        let outcome = await ControlScans.loginItems()
        let json = ControlScans.loginItemsJSON(outcome.items, diagnostics: outcome.diagnostics)
        return ControlResponse.success(for: request, text: json.text, result: json.result)
    }

    // MARK: - Helpers

    private func usageFailure(_ request: ControlRequest, hint: String) -> ControlResponse {
        let usage = CommandCatalog.command(named: request.command).map { "usage: \($0.usage)" }
        return ControlResponse(
            id: request.id,
            command: request.command,
            ok: false,
            text: usage.map { [$0] },
            error: ControlErrorPayload(code: .usage, message: hint, hint: usage)
        )
    }
}

// MARK: - Usage refresh waiter

/// Bridges the monitor's published refresh flag to one bounded await. The
/// control server never polls: a command that asks for fresh usage waits for the
/// same batch the UI uses, and gives up with a warning rather than hanging.
@MainActor
private final class UsageRefreshWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var cancellable: AnyCancellable?
    private var timeoutTask: Task<Void, Never>?

    func wait(for usage: AIUsageMonitor, timeout: TimeInterval) async -> Bool {
        guard usage.isRefreshing else { return true }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.cancellable = usage.$isRefreshing.sink { [weak self] refreshing in
                guard !refreshing else { return }
                Task { @MainActor in self?.finish(true) }
            }
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(false)
            }
        }
    }

    func cancel() {
        finish(false)
    }

    private func finish(_ value: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        cancellable?.cancel()
        cancellable = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(returning: value)
    }
}
