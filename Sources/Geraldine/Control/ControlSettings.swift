import Foundation
import GeraldineControl

enum ControlSettingsError: Error, LocalizedError {
    case readOnly(String)
    case unknownKey(String)
    case invalidValue(key: String, message: String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .readOnly(let key): return "\"\(key)\" is read-only."
        case .unknownKey(let key): return "Unknown setting \"\(key)\"."
        case .invalidValue(let key, let message): return "Invalid value for \(key): \(message)"
        case .failed(let message): return message
        }
    }
}

enum ControlWidgetError: Error, LocalizedError {
    case unknownWidget(String)
    case unknownSize(String)
    case unknownTarget(String)
    case notResizable(String)

    var errorDescription: String? {
        switch self {
        case .unknownWidget(let id): return "Unknown widget \"\(id)\"."
        case .unknownSize(let size): return "Unknown widget size \"\(size)\"."
        case .unknownTarget(let id): return "The layout has no widget \"\(id)\"."
        case .notResizable(let id): return "Widget \"\(id)\" cannot be resized."
        }
    }
}

/// The live settings surface. Every setter goes through the same controller the
/// UI uses, so it applies immediately and persists through the existing didSet
/// hooks. Nothing here writes a preference behind a live object's back.
@MainActor
final class ControlSettings {
    private var state: AppState { .shared }
    private let defaults: UserDefaults
    private let keepAwakeProvider: @MainActor () -> KeepAwakeController
    private var keepAwake: KeepAwakeController { keepAwakeProvider() }
    private var calendar: CalendarSettingsStore { state.calendar }
    private var tools: PowerToolsController { state.powerTools }

    init(
        defaults: UserDefaults = .standard,
        keepAwake: @escaping @MainActor () -> KeepAwakeController = { AppState.shared.keepAwake }
    ) {
        self.defaults = defaults
        self.keepAwakeProvider = keepAwake
    }

    // MARK: - Reading

    func snapshot() -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for definition in SettingsCatalog.definitions {
            values[definition.key] = value(for: definition)
        }
        return values
    }

    func value(for definition: SettingDefinition) -> JSONValue {
        let key = definition.key

        switch key {
        case "keepAwake.defaultDuration":
            return .string(keepAwake.defaultDuration.rawValue)
        case "keepAwake.allowDisplaySleep":
            return .bool(keepAwake.allowDisplaySleep)
        case "keepAwake.deactivateOnBattery":
            return .bool(keepAwake.deactivateOnBattery)
        case "keepAwake.pauseWhenScreenLocked":
            return .bool(keepAwake.pauseWhenScreenLocked)
        case "keepAwake.simulateIdleActivity":
            return .bool(keepAwake.simulateIdleActivity)
        case "keepAwake.idleActivityDelayMinutes":
            return .int(keepAwake.idleActivityDelayMinutes)
        case "appShape":
            return .string(state.appShape.rawValue)
        case "networkRateUnit":
            return .string((defaults.string(forKey: "networkRateUnit"))
                .flatMap(NetworkRateUnit.init(rawValue:))?.rawValue
                ?? NetworkRateUnit.bytesPerSecond.rawValue)
        case "launchAtLogin":
            return .bool(LaunchAtLogin.isEnabled)
        case "menuBar.metric":
            return .string(state.layout.menuBarKind(hasBattery: state.monitor.hasBattery).rawValue)
        case "geraldine.widgetLayout.v3":
            return layoutValue()
        case "geraldine.aiUsage.connected":
            return connectedUsageValue()
        case "powerTools.dock.actionsEnabled":
            return .bool(tools.dockActionsEnabled)
        case "powerTools.dock.windowPreviewsEnabled":
            return .bool(tools.dockWindowPreviewsEnabled)
        case "powerTools.dock.activeClickBehavior":
            return .string(tools.activeDockClickBehavior.rawValue)
        case "powerTools.dock.middleClickBehavior":
            return .string(tools.middleClickBehavior.rawValue)
        case "powerTools.dock.shiftClickNewWindow":
            return .bool(tools.shiftClickNewWindow)
        case "powerTools.window.unminimizeOnActivation":
            return .bool(tools.unminimizeOnActivation)
        case "powerTools.window.greenButtonFillsWindow":
            return .bool(tools.greenButtonFillsWindow)
        case "powerTools.window.yellowButtonHidesApp":
            return .bool(tools.yellowButtonHidesApp)
        case "powerTools.window.missionControlTwoFingerClose":
            return .bool(tools.missionControlTwoFingerClose)
        case "powerTools.keyboard.commandQDoubleTap":
            return .bool(tools.commandQDoubleTap)
        case "powerTools.keyboard.commandWDoubleTap":
            return .bool(tools.commandWDoubleTap)
        case "powerTools.finder.returnOpens":
            return .bool(tools.finderReturnOpens)
        case "powerTools.finder.cutPaste":
            return .bool(tools.finderCutPaste)
        case "powerTools.finder.optionNNewFile":
            return .bool(tools.finderOptionNNewFile)
        case "powerTools.finder.backspaceMovesToTrash":
            return .bool(tools.finderBackspaceMovesToTrash)
        case "calendar.showCalendar":
            return .bool(calendar.showCalendar)
        case "calendar.firstWeekday":
            return SettingsCatalog.exposedValue(.int(calendar.firstWeekday.rawValue), for: definition)
        case "calendar.showWeekNumbers":
            return .bool(calendar.showWeekNumbers)
        case "calendar.highlightWeekends":
            return .bool(calendar.highlightWeekends)
        case "calendar.clockStyle":
            return .string(calendar.clockStyle.rawValue)
        case "calendar.showSeconds":
            return .bool(calendar.showSeconds)
        case "calendar.dateStyle":
            return .string(calendar.dateStyle.rawValue)
        case "calendar.customDateFormat":
            return .string(calendar.customDateFormat)
        case "calendar.showWorldClocks":
            return .bool(calendar.showWorldClocks)
        case "calendar.showDayNightIcons":
            return .bool(calendar.showDayNightIcons)
        case "calendar.showTimeTravel":
            return .bool(calendar.showTimeTravel)
        case "calendar.worldClocks.v1":
            return .array(calendar.clocks.map { clock in
                .object([
                    "timeZoneID": .string(clock.timeZoneID),
                    "label": .string(clock.label)
                ])
            })
        default:
            return definition.defaultValue
        }
    }

    func definitionsValue() -> JSONValue {
        .array(SettingsCatalog.definitions.map { definition in
            .object([
                "key": .string(definition.key),
                "summary": .string(definition.summary),
                "kind": .string(definition.kind.rawValue),
                "options": .array(definition.options.map { .string($0) }),
                "default": definition.defaultValue,
                "requiresRunningApp": .bool(definition.requiresRunningApp),
                "readOnly": .bool(definition.readOnly),
                "sideEffects": .array(definition.sideEffects.map { .string($0) })
            ])
        })
    }

    // MARK: - Writing

    func set(key: String, rawValue: String) throws -> (previous: JSONValue, current: JSONValue) {
        guard let definition = SettingsCatalog.definition(for: key) else {
            throw ControlSettingsError.unknownKey(key)
        }
        guard !definition.readOnly else {
            throw ControlSettingsError.readOnly(key)
        }
        let value: JSONValue
        do {
            value = try SettingsCatalog.parse(rawValue, for: definition)
        } catch {
            throw ControlSettingsError.invalidValue(key: key, message: error.localizedDescription)
        }
        let previous = self.value(for: definition)
        try apply(definition: definition, value: value)
        let current = self.value(for: definition)
        return (previous, current)
    }

    private func apply(definition: SettingDefinition, value: JSONValue) throws {
        switch definition.key {
        case "keepAwake.defaultDuration":
            guard let raw = value.stringValue,
                  let duration = KeepAwakeDuration(rawValue: raw) else {
                throw ControlSettingsError.invalidValue(key: definition.key, message: "expected a Keep Awake duration")
            }
            keepAwake.defaultDuration = duration
        case "keepAwake.allowDisplaySleep":
            keepAwake.allowDisplaySleep = try bool(value, definition)
        case "keepAwake.deactivateOnBattery":
            keepAwake.deactivateOnBattery = try bool(value, definition)
        case "keepAwake.pauseWhenScreenLocked":
            keepAwake.pauseWhenScreenLocked = try bool(value, definition)
        case "keepAwake.simulateIdleActivity":
            keepAwake.simulateIdleActivity = try bool(value, definition)
        case "keepAwake.idleActivityDelayMinutes":
            guard let minutes = value.intValue else {
                throw ControlSettingsError.invalidValue(key: definition.key, message: "expected an integer")
            }
            keepAwake.idleActivityDelayMinutes = minutes
        case "appShape":
            guard let raw = value.stringValue, let shape = AppShape(rawValue: raw) else {
                throw ControlSettingsError.invalidValue(key: definition.key, message: "expected an app shape")
            }
            state.appShape = shape
        case "networkRateUnit":
            guard let raw = value.stringValue, NetworkRateUnit(rawValue: raw) != nil else {
                throw ControlSettingsError.invalidValue(key: definition.key, message: "expected bytesPerSecond or bitsPerSecond")
            }
            defaults.set(raw, forKey: "networkRateUnit")
        case "launchAtLogin":
            let enabled = try bool(value, definition)
            guard LaunchAtLogin.set(enabled) else {
                throw ControlSettingsError.failed(
                    "macOS rejected the login-item change. Allow Geraldine in System Settings > General > Login Items."
                )
            }
        case "menuBar.metric":
            guard let raw = value.stringValue, let metric = MetricKind(rawValue: raw) else {
                throw ControlSettingsError.invalidValue(key: definition.key, message: "expected a metric")
            }
            state.layout.setShown(.metric(metric), true)
            state.layout.moveToFront(.metric(metric))
        case "geraldine.widgetLayout.v3":
            try applyLayout(value)
        case "powerTools.dock.actionsEnabled":
            tools.dockActionsEnabled = try bool(value, definition)
        case "powerTools.dock.windowPreviewsEnabled":
            tools.dockWindowPreviewsEnabled = try bool(value, definition)
        case "powerTools.dock.activeClickBehavior":
            guard let raw = value.stringValue, let behavior = DockActiveClickBehavior(rawValue: raw) else {
                throw ControlSettingsError.invalidValue(key: definition.key, message: "expected a Dock active-click behavior")
            }
            tools.activeDockClickBehavior = behavior
        case "powerTools.dock.middleClickBehavior":
            guard let raw = value.stringValue, let behavior = DockMiddleClickBehavior(rawValue: raw) else {
                throw ControlSettingsError.invalidValue(key: definition.key, message: "expected a Dock middle-click behavior")
            }
            tools.middleClickBehavior = behavior
        case "powerTools.dock.shiftClickNewWindow":
            tools.shiftClickNewWindow = try bool(value, definition)
        case "powerTools.window.unminimizeOnActivation":
            tools.unminimizeOnActivation = try bool(value, definition)
        case "powerTools.window.greenButtonFillsWindow":
            tools.greenButtonFillsWindow = try bool(value, definition)
        case "powerTools.window.yellowButtonHidesApp":
            tools.yellowButtonHidesApp = try bool(value, definition)
        case "powerTools.window.missionControlTwoFingerClose":
            tools.missionControlTwoFingerClose = try bool(value, definition)
        case "powerTools.keyboard.commandQDoubleTap":
            tools.commandQDoubleTap = try bool(value, definition)
        case "powerTools.keyboard.commandWDoubleTap":
            tools.commandWDoubleTap = try bool(value, definition)
        case "powerTools.finder.returnOpens":
            tools.finderReturnOpens = try bool(value, definition)
        case "powerTools.finder.cutPaste":
            tools.finderCutPaste = try bool(value, definition)
        case "powerTools.finder.optionNNewFile":
            tools.finderOptionNNewFile = try bool(value, definition)
        case "powerTools.finder.backspaceMovesToTrash":
            tools.finderBackspaceMovesToTrash = try bool(value, definition)
        case "calendar.showCalendar":
            calendar.showCalendar = try bool(value, definition)
        case "calendar.firstWeekday":
            guard let stored = SettingsCatalog.storedValue(value, for: definition).intValue,
                  let weekday = FirstWeekday(rawValue: stored) else {
                throw ControlSettingsError.invalidValue(key: definition.key, message: "expected a weekday")
            }
            calendar.firstWeekday = weekday
        case "calendar.showWeekNumbers":
            calendar.showWeekNumbers = try bool(value, definition)
        case "calendar.highlightWeekends":
            calendar.highlightWeekends = try bool(value, definition)
        case "calendar.clockStyle":
            guard let raw = value.stringValue, let style = ClockStyle(rawValue: raw) else {
                throw ControlSettingsError.invalidValue(key: definition.key, message: "expected a clock style")
            }
            calendar.clockStyle = style
        case "calendar.showSeconds":
            calendar.showSeconds = try bool(value, definition)
        case "calendar.dateStyle":
            guard let raw = value.stringValue, let style = DateStyle(rawValue: raw) else {
                throw ControlSettingsError.invalidValue(key: definition.key, message: "expected a date style")
            }
            calendar.dateStyle = style
        case "calendar.customDateFormat":
            guard let raw = value.stringValue else {
                throw ControlSettingsError.invalidValue(key: definition.key, message: "expected a date format")
            }
            calendar.customDateFormat = raw
        case "calendar.showWorldClocks":
            calendar.showWorldClocks = try bool(value, definition)
        case "calendar.showDayNightIcons":
            calendar.showDayNightIcons = try bool(value, definition)
        case "calendar.showTimeTravel":
            calendar.showTimeTravel = try bool(value, definition)
        case "calendar.worldClocks.v1":
            calendar.clocks = try clocks(from: value)
        default:
            throw ControlSettingsError.unknownKey(definition.key)
        }
    }

    private func bool(_ value: JSONValue, _ definition: SettingDefinition) throws -> Bool {
        guard let flag = value.boolValue else {
            throw ControlSettingsError.invalidValue(key: definition.key, message: "expected true or false")
        }
        return flag
    }

    private func clocks(from value: JSONValue) throws -> [WorldClock] {
        guard let array = value.arrayValue else {
            throw ControlSettingsError.invalidValue(
                key: "calendar.worldClocks.v1",
                message: "expected a JSON array of {timeZoneID,label}"
            )
        }
        var clocks: [WorldClock] = []
        for element in array {
            guard let object = element.objectValue,
                  let identifier = object["timeZoneID"]?.stringValue,
                  TimeZone(identifier: identifier) != nil else {
                throw ControlSettingsError.invalidValue(
                    key: "calendar.worldClocks.v1",
                    message: "each clock needs a valid IANA timeZoneID"
                )
            }
            clocks.append(WorldClock(
                timeZoneID: identifier,
                label: object["label"]?.stringValue ?? ""
            ))
        }
        return clocks
    }

    private func applyLayout(_ value: JSONValue) throws {
        guard let array = value.arrayValue, !array.isEmpty else {
            throw ControlSettingsError.invalidValue(
                key: "geraldine.widgetLayout.v3",
                message: "expected a non-empty JSON array of {kind,size,isShown}"
            )
        }
        var items: [WidgetItem] = []
        for element in array {
            guard let object = element.objectValue,
                  let identifier = object["kind"]?.stringValue,
                  let kind = WidgetKind(id: identifier) else {
                throw ControlSettingsError.invalidValue(
                    key: "geraldine.widgetLayout.v3",
                    message: "each item needs a known kind"
                )
            }
            let size: WidgetSize
            if let rawSize = object["size"]?.stringValue {
                guard let parsed = WidgetSize(rawValue: rawSize) else {
                    throw ControlSettingsError.invalidValue(
                        key: "geraldine.widgetLayout.v3",
                        message: "unknown size \"\(rawSize)\""
                    )
                }
                size = parsed
            } else {
                size = kind.canResize ? .small : .large
            }
            let isShown = object["isShown"]?.boolValue ?? true
            items.append(WidgetItem(kind, size, isShown: isShown))
        }
        state.layout.replaceItems(items)
    }

    // MARK: - Layout values

    func layoutValue() -> JSONValue {
        .array(state.layout.items.map { item in
            .object([
                "kind": .string(item.kind.id),
                "title": .string(item.kind.title),
                "size": .string(item.size.rawValue),
                "isShown": .bool(item.isShown),
                "canResize": .bool(item.kind.canResize)
            ])
        })
    }

    private func connectedUsageValue() -> JSONValue {
        let identities = state.layout.items.compactMap { item -> String? in
            guard item.isShown, case .aiUsage(let identity) = item.kind else { return nil }
            return identity.id
        }.sorted()
        return .array(identities.map { .string($0) })
    }

    // MARK: - Widgets

    func widgetsListText() -> [String] {
        var lines = ["Widgets in popover order:"]
        let barKind = state.layout.menuBarKind(hasBattery: state.monitor.hasBattery)
        for item in state.layout.items {
            let marker = item.isShown ? "[x]" : "[ ]"
            var detail = "\(item.kind.title) — \(item.size.rawValue)"
            if item.kind.metric == barKind {
                detail += " (menu bar)"
            }
            lines.append("  \(marker) \(item.kind.id)  \(detail)")
        }
        lines.append("The first shown metric drives the menu-bar item.")
        return lines
    }

    func widgetsListResult() -> JSONValue {
        .object([
            "items": layoutValue(),
            "menuBarMetric": .string(state.layout.menuBarKind(hasBattery: state.monitor.hasBattery).rawValue)
        ])
    }

    func widgetsAction(
        subcommand: String,
        arguments: [String],
        options: [String: String]
    ) throws -> (result: JSONValue, text: [String]) {
        let layout = state.layout
        func kind(_ identifier: String) throws -> WidgetKind {
            guard let kind = WidgetKind(id: identifier) else {
                throw ControlWidgetError.unknownWidget(identifier)
            }
            guard layout.items.contains(where: { $0.kind == kind }) else {
                throw ControlWidgetError.unknownTarget(identifier)
            }
            return kind
        }

        var message: String
        switch subcommand {
        case "list":
            return (widgetsListResult(), widgetsListText())
        case "show", "hide":
            let target = try kind(arguments[1])
            let shown = subcommand == "show"
            layout.setShown(target, shown)
            message = "\(shown ? "Showed" : "Hid") \(target.title)."
        case "size":
            let target = try kind(arguments[1])
            guard target.canResize else {
                throw ControlWidgetError.notResizable(target.id)
            }
            guard let size = WidgetSize(rawValue: arguments[2]) else {
                throw ControlWidgetError.unknownSize(arguments[2])
            }
            layout.setSize(target, size)
            message = "Set \(target.title) to \(size.rawValue)."
        case "move":
            let target = try kind(arguments[1])
            if options["position"] == "before" {
                guard let identifier = options["before"] else {
                    throw ControlWidgetError.unknownTarget("(missing)")
                }
                let anchor = try kind(identifier)
                guard anchor != target else {
                    throw ControlWidgetError.unknownTarget(identifier)
                }
                layout.move(target, before: anchor)
                message = "Moved \(target.title) before \(anchor.title)."
            } else {
                layout.moveToFront(target)
                message = "Moved \(target.title) to the front."
            }
        case "reset":
            layout.reset()
            message = "Reset the popover layout to Geraldine's defaults."
        default:
            throw ControlWidgetError.unknownWidget(subcommand)
        }

        var text = [message, "Menu bar: \(layout.menuBarKind(hasBattery: state.monitor.hasBattery).title)."]
        text.append(contentsOf: widgetsListText())
        return (widgetsListResult(), text)
    }
}
