import Foundation

/// A small, dependency-free JSON tree used by the control protocol and the CLI.
/// Keeping one representation means the socket, the command catalog, and the
/// command line all agree on how values are encoded.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Convert Foundation JSON objects into `JSONValue`. Used only for reading
    /// preference values that the app stored as `Data`.
    public static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let value as NSNumber:
            // Foundation bridges numeric 0/1 to Bool too. Inspect the actual
            // CFBoolean type before any Swift conditional numeric casts.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let type = String(cString: value.objCType)
            if "cCsSiIlLqQ".contains(type), let integer = Int(value.stringValue) {
                // Never round an exact Int64 through Double (Int64.max would
                // become 2^63). Floating point values keep their own type.
                return .int(integer)
            }
            return .double(value.doubleValue)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(value.map(JSONValue.from))
        case let value as [String: Any]:
            return .object(value.mapValues(JSONValue.from))
        default:
            return .string(String(describing: any))
        }
    }

    /// Human-oriented rendering for values shown in `settings list` and other
    /// tabular output. Strings are unquoted; structured values are compact JSON.
    public var displayString: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .array, .object:
            return JSONValue.encodeLine(self) ?? "null"
        }
    }

    public static func encodeLine(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
