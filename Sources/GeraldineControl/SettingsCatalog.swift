import Foundation

public enum SettingKind: String, Codable, Sendable {
    case bool
    case int
    case enumeration
    case string
    case json
}

public struct SettingDefinition: Codable, Equatable, Sendable {
    public var key: String
    public var summary: String
    public var kind: SettingKind
    public var options: [String]
    /// Optional mapping from an agent-facing option name to the value the app
    /// actually persists. Calendar weekdays use this to keep their legacy Int.
    public var optionStorage: [String: JSONValue]?
    public var defaultValue: JSONValue
    public var requiresRunningApp: Bool
    public var readOnly: Bool
    public var sideEffects: [String]

    public init(
        key: String,
        summary: String,
        kind: SettingKind,
        options: [String] = [],
        optionStorage: [String: JSONValue]? = nil,
        defaultValue: JSONValue,
        requiresRunningApp: Bool = false,
        readOnly: Bool = false,
        sideEffects: [String] = []
    ) {
        self.key = key
        self.summary = summary
        self.kind = kind
        self.options = options
        self.optionStorage = optionStorage
        self.defaultValue = defaultValue
        self.requiresRunningApp = requiresRunningApp
        self.readOnly = readOnly
        self.sideEffects = sideEffects
    }
}

public enum SettingError: Error, LocalizedError, Equatable {
    case unknownKey(String)
    case readOnly(String)
    case invalidValue(key: String, message: String)
    case needsRunningApp(String)

    public var errorDescription: String? {
        switch self {
        case .unknownKey(let key):
            return "Unknown setting \"\(key)\"."
        case .readOnly(let key):
            return "\"\(key)\" is read-only."
        case .invalidValue(let key, let message):
            return "Invalid value for \(key): \(message)"
        case .needsRunningApp(let key):
            return "\"\(key)\" is only available while Geraldine is running."
        }
    }
}

public enum SettingsCatalog {
    public static let suiteName = "com.vincent.geraldine"

    private static let keepAwakeEffects = ["Updates the live Keep Awake session or the next one."]
    private static let powerToolEffects = ["Reloads the active Power Tools event hooks immediately."]
    private static let calendarEffects = ["Refreshes the calendar and world clocks immediately."]

    public static let definitions: [SettingDefinition] = [
        // Keep Awake
        SettingDefinition(
            key: "keepAwake.defaultDuration",
            summary: "Default Keep Awake duration. Active sessions keep their current duration.",
            kind: .enumeration,
            options: ["tenMinutes", "thirtyMinutes", "oneHour", "twoHours", "fourHours", "eightHours", "twelveHours", "indefinitely"],
            defaultValue: .string("oneHour"),
            sideEffects: keepAwakeEffects
        ),
        SettingDefinition(
            key: "keepAwake.allowDisplaySleep",
            summary: "Allow the display to sleep while Keep Awake prevents system idle sleep.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: ["Re-creates the Keep Awake power assertions."]
        ),
        SettingDefinition(
            key: "keepAwake.deactivateOnBattery",
            summary: "Turn Keep Awake off when the Mac switches to battery power.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: ["May end an active Keep Awake session immediately."]
        ),
        SettingDefinition(
            key: "keepAwake.pauseWhenScreenLocked",
            summary: "Release power assertions while the login session is locked.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: ["May pause or resume the active Keep Awake session."]
        ),
        SettingDefinition(
            key: "keepAwake.simulateIdleActivity",
            summary: "Stay Active: pulse synthetic input while Keep Awake is running.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: ["Starts or stops the Stay Active simulator."]
        ),
        SettingDefinition(
            key: "keepAwake.idleActivityDelayMinutes",
            summary: "Minutes of user idle time before Stay Active pulses.",
            kind: .int,
            options: ["1", "2", "5"],
            defaultValue: .int(2),
            sideEffects: ["Restarts the Stay Active timer with the new delay."]
        ),

        // App behavior
        SettingDefinition(
            key: "appShape",
            summary: "Where Geraldine appears: menu bar, Dock, or both.",
            kind: .enumeration,
            options: ["menuBarAndWindow", "menuBarOnly", "windowOnly"],
            defaultValue: .string("menuBarAndWindow"),
            sideEffects: ["Changes the activation policy and may show or hide the main window."]
        ),
        SettingDefinition(
            key: "networkRateUnit",
            summary: "Unit used for live network rates.",
            kind: .enumeration,
            options: ["bytesPerSecond", "bitsPerSecond"],
            defaultValue: .string("bytesPerSecond"),
            sideEffects: ["Updates the dashboard, popover, and menu bar immediately."]
        ),
        SettingDefinition(
            key: "launchAtLogin",
            summary: "Whether Geraldine registers itself to open at login.",
            kind: .bool,
            defaultValue: .bool(false),
            requiresRunningApp: true,
            sideEffects: ["Registers or unregisters the main app with ServiceManagement."]
        ),
        SettingDefinition(
            key: "menuBar.metric",
            summary: "Metric shown live in the menu-bar status item.",
            kind: .enumeration,
            options: ["temperature", "cpu", "gpu", "memory", "storage", "battery", "network"],
            defaultValue: .string("temperature"),
            requiresRunningApp: true,
            sideEffects: ["Shows the widget and moves it to the front of the layout."]
        ),
        SettingDefinition(
            key: "geraldine.widgetLayout.v3",
            summary: "Full widget layout as a JSON array of {kind,size,isShown}.",
            kind: .json,
            defaultValue: .null,
            requiresRunningApp: true,
            sideEffects: ["Replaces the popover layout and may change the menu-bar metric."]
        ),
        SettingDefinition(
            key: "geraldine.aiUsage.connected",
            summary: "Identities currently feeding coding-usage tiles. Derived from the layout.",
            kind: .json,
            defaultValue: .array([]),
            requiresRunningApp: true,
            readOnly: true,
            sideEffects: []
        ),

        // Power Tools
        SettingDefinition(
            key: "powerTools.dock.actionsEnabled",
            summary: "Enable custom Dock click actions.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.dock.windowPreviewsEnabled",
            summary: "Show window previews when hovering Dock apps.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.dock.activeClickBehavior",
            summary: "Action for clicking the active app's Dock icon.",
            kind: .enumeration,
            options: ["system", "hideApp", "minimizeWindows", "cycleWindows"],
            defaultValue: .string("system"),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.dock.middleClickBehavior",
            summary: "Action for middle-clicking a Dock icon.",
            kind: .enumeration,
            options: ["system", "hideApp", "minimizeWindows", "newWindow", "quitApp"],
            defaultValue: .string("system"),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.dock.shiftClickNewWindow",
            summary: "Open a new window when shift-clicking a Dock icon.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.window.unminimizeOnActivation",
            summary: "Unminimize an app's windows when it becomes active.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.window.greenButtonFillsWindow",
            summary: "Make the green button fill the screen instead of entering full screen.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.window.yellowButtonHidesApp",
            summary: "Make the yellow button hide the whole app.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.window.missionControlTwoFingerClose",
            summary: "Close Mission Control with a two-finger gesture.",
            kind: .bool,
            defaultValue: .bool(true),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.keyboard.commandQDoubleTap",
            summary: "Require a double press of Command-Q to quit apps.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.keyboard.commandWDoubleTap",
            summary: "Require a double press of Command-W to close windows.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.finder.returnOpens",
            summary: "Open the selected Finder item with Return.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.finder.cutPaste",
            summary: "Enable cut and paste for Finder files.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.finder.optionNNewFile",
            summary: "Create a new file in Finder with Option-N.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),
        SettingDefinition(
            key: "powerTools.finder.backspaceMovesToTrash",
            summary: "Move the selected Finder item to the Trash with Backspace.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: powerToolEffects
        ),

        // Calendar and clocks
        SettingDefinition(
            key: "calendar.showCalendar",
            summary: "Show the month grid in the popover.",
            kind: .bool,
            defaultValue: .bool(true),
            sideEffects: calendarEffects
        ),
        SettingDefinition(
            key: "calendar.firstWeekday",
            summary: "First day of the calendar week.",
            kind: .enumeration,
            options: ["system", "sunday", "monday", "saturday"],
            optionStorage: [
                "system": .int(0),
                "sunday": .int(1),
                "monday": .int(2),
                "saturday": .int(7)
            ],
            defaultValue: .string("system"),
            sideEffects: calendarEffects
        ),
        SettingDefinition(
            key: "calendar.showWeekNumbers",
            summary: "Show ISO week numbers in the month grid.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: calendarEffects
        ),
        SettingDefinition(
            key: "calendar.highlightWeekends",
            summary: "Tint Saturday and Sunday.",
            kind: .bool,
            defaultValue: .bool(true),
            sideEffects: calendarEffects
        ),
        SettingDefinition(
            key: "calendar.clockStyle",
            summary: "Clock format for the popover and world clocks.",
            kind: .enumeration,
            options: ["system", "twelveHour", "twentyFourHour"],
            defaultValue: .string("system"),
            sideEffects: calendarEffects
        ),
        SettingDefinition(
            key: "calendar.showSeconds",
            summary: "Show seconds in the live clock.",
            kind: .bool,
            defaultValue: .bool(false),
            sideEffects: calendarEffects
        ),
        SettingDefinition(
            key: "calendar.dateStyle",
            summary: "Date format above the month grid.",
            kind: .enumeration,
            options: ["full", "long", "medium", "custom"],
            defaultValue: .string("full"),
            sideEffects: calendarEffects
        ),
        SettingDefinition(
            key: "calendar.customDateFormat",
            summary: "DateFormatter pattern used when dateStyle is custom.",
            kind: .string,
            defaultValue: .string("EEEE, MMM d"),
            sideEffects: calendarEffects
        ),
        SettingDefinition(
            key: "calendar.showWorldClocks",
            summary: "Show configured world clocks below the calendar.",
            kind: .bool,
            defaultValue: .bool(true),
            sideEffects: calendarEffects
        ),
        SettingDefinition(
            key: "calendar.showDayNightIcons",
            summary: "Show day and night icons beside world clocks.",
            kind: .bool,
            defaultValue: .bool(true),
            sideEffects: calendarEffects
        ),
        SettingDefinition(
            key: "calendar.showTimeTravel",
            summary: "Show the time-travel controls in the calendar.",
            kind: .bool,
            defaultValue: .bool(true),
            sideEffects: calendarEffects
        ),
        SettingDefinition(
            key: "calendar.worldClocks.v1",
            summary: "World clocks as a JSON array of {timeZoneID,label}.",
            kind: .json,
            defaultValue: .array([]),
            sideEffects: calendarEffects
        )
    ]

    public static func definition(for key: String) -> SettingDefinition? {
        definitions.first { $0.key == key }
    }

    public static func parse(_ raw: String, for definition: SettingDefinition) throws -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch definition.kind {
        case .bool:
            switch trimmed.lowercased() {
            case "true", "yes", "on", "1": return .bool(true)
            case "false", "no", "off", "0": return .bool(false)
            default:
                throw SettingError.invalidValue(key: definition.key, message: "expected true or false")
            }
        case .int:
            guard let value = Int(trimmed) else {
                throw SettingError.invalidValue(key: definition.key, message: "expected an integer")
            }
            if !definition.options.isEmpty, !definition.options.contains(String(value)) {
                throw SettingError.invalidValue(
                    key: definition.key,
                    message: "expected one of \(definition.options.joined(separator: ", "))"
                )
            }
            return .int(value)
        case .enumeration:
            guard let option = definition.options.first(where: {
                $0.caseInsensitiveCompare(trimmed) == .orderedSame
            }) else {
                throw SettingError.invalidValue(
                    key: definition.key,
                    message: "expected one of \(definition.options.joined(separator: ", "))"
                )
            }
            return .string(option)
        case .string:
            return .string(trimmed)
        case .json:
            guard let data = trimmed.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw SettingError.invalidValue(key: definition.key, message: "expected valid JSON")
            }
            return value
        }
    }

    public static func validate(_ value: JSONValue, for definition: SettingDefinition) throws -> JSONValue {
        switch definition.kind {
        case .bool:
            guard value.boolValue != nil else {
                throw SettingError.invalidValue(key: definition.key, message: "expected true or false")
            }
            return value
        case .int:
            guard let number = value.intValue else {
                throw SettingError.invalidValue(key: definition.key, message: "expected an integer")
            }
            if !definition.options.isEmpty, !definition.options.contains(String(number)) {
                throw SettingError.invalidValue(
                    key: definition.key,
                    message: "expected one of \(definition.options.joined(separator: ", "))"
                )
            }
            return .int(number)
        case .enumeration:
            guard let option = value.stringValue,
                  let canonical = definition.options.first(where: {
                      $0.caseInsensitiveCompare(option) == .orderedSame
                  }) else {
                throw SettingError.invalidValue(
                    key: definition.key,
                    message: "expected one of \(definition.options.joined(separator: ", "))"
                )
            }
            return .string(canonical)
        case .string:
            guard value.stringValue != nil else {
                throw SettingError.invalidValue(key: definition.key, message: "expected a string")
            }
            return value
        case .json:
            return value
        }
    }

    /// The value written to `UserDefaults` for a validated agent-facing value.
    public static func storedValue(_ value: JSONValue, for definition: SettingDefinition) -> JSONValue {
        if let storage = definition.optionStorage,
           let option = value.stringValue,
           let stored = storage[option] {
            return stored
        }
        return value
    }

    /// Turn a persisted value back into the agent-facing form.
    public static func exposedValue(_ stored: JSONValue, for definition: SettingDefinition) -> JSONValue {
        guard let storage = definition.optionStorage else { return stored }
        for (name, value) in storage where value == stored {
            return .string(name)
        }
        return stored
    }
}
