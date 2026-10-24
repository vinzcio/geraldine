import Foundation

/// Reads the app's preference domain without the app running. This is the
/// read-only fallback for `settings list` and `settings get`; it never writes
/// and never fabricates a virtual value such as `launchAtLogin`.
public struct SettingsReader {
    public let defaults: UserDefaults
    public let appRunning: Bool

    public init(
        suiteName: String = SettingsCatalog.suiteName,
        appRunning: Bool = false
    ) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.appRunning = appRunning
    }

    public init(defaults: UserDefaults, appRunning: Bool = false) {
        self.defaults = defaults
        self.appRunning = appRunning
    }

    public func snapshot() -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for definition in SettingsCatalog.definitions {
            guard let value = value(for: definition) else { continue }
            values[definition.key] = value
        }
        return values
    }

    public func value(for definition: SettingDefinition) -> JSONValue? {
        guard !definition.requiresRunningApp else { return nil }
        guard let raw = defaults.object(forKey: definition.key) else {
            return definition.defaultValue
        }

        switch definition.kind {
        case .bool:
            guard let value = raw as? Bool else { return definition.defaultValue }
            return .bool(value)
        case .int:
            guard let value = raw as? Int else { return definition.defaultValue }
            return .int(value)
        case .enumeration, .string:
            guard let value = raw as? String else {
                if let number = raw as? Int {
                    return SettingsCatalog.exposedValue(.int(number), for: definition)
                }
                return definition.defaultValue
            }
            if definition.kind == .enumeration {
                return SettingsCatalog.exposedValue(.string(value), for: definition)
            }
            return .string(value)
        case .json:
            if let data = raw as? Data,
               let object = try? JSONSerialization.jsonObject(with: data),
               JSONSerialization.isValidJSONObject(object) {
                return JSONValue.from(object)
            }
            if let value = raw as? JSONValue {
                return value
            }
            if let array = raw as? [Any] {
                return .array(array.map(JSONValue.from))
            }
            return definition.defaultValue
        }
    }
}
