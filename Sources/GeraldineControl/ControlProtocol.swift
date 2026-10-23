import Foundation

public enum ControlProtocol {
    /// Bumped only for a breaking wire-format change.
    public static let version = 1
    /// Bumped only for a breaking response-schema change.
    public static let schemaVersion = 1
    /// A request or response larger than this is rejected rather than buffered.
    public static let maximumLineBytes = 1_048_576
}

public enum ControlErrorCode: String, Codable, Sendable {
    case usage
    case failed
    case notRunning
    case permission
    case unsupported
    case invalidValue
}

public struct ControlErrorPayload: Codable, Equatable, Sendable {
    public var code: ControlErrorCode
    public var message: String
    public var hint: String?

    public init(code: ControlErrorCode, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    /// Exit status mapping shared by the CLI and its tests.
    public var exitCode: Int32 {
        switch code {
        case .usage, .invalidValue: return 2
        case .notRunning, .unsupported: return 3
        case .permission: return 4
        case .failed: return 1
        }
    }
}

public struct ControlRequest: Codable, Sendable {
    public var protocolVersion: Int
    public var id: String
    public var command: String
    public var arguments: [String]
    public var options: [String: String]

    public init(
        id: String = UUID().uuidString,
        command: String,
        arguments: [String] = [],
        options: [String: String] = [:],
        protocolVersion: Int = ControlProtocol.version
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.command = command
        self.arguments = arguments
        self.options = options
    }
}

public struct ControlResponse: Codable, Sendable {
    public var protocolVersion: Int
    public var schemaVersion: Int
    public var id: String
    public var command: String
    public var ok: Bool
    public var text: [String]?
    public var result: JSONValue?
    public var warnings: [String]
    public var error: ControlErrorPayload?

    public init(
        protocolVersion: Int = ControlProtocol.version,
        schemaVersion: Int = ControlProtocol.schemaVersion,
        id: String = UUID().uuidString,
        command: String,
        ok: Bool,
        text: [String]? = nil,
        result: JSONValue? = nil,
        warnings: [String] = [],
        error: ControlErrorPayload? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.schemaVersion = schemaVersion
        self.id = id
        self.command = command
        self.ok = ok
        self.text = text
        self.result = result
        self.warnings = warnings
        self.error = error
    }

    public static func success(
        for request: ControlRequest,
        text: [String]? = nil,
        result: JSONValue? = nil,
        warnings: [String] = []
    ) -> ControlResponse {
        ControlResponse(
            id: request.id,
            command: request.command,
            ok: true,
            text: text,
            result: result,
            warnings: warnings
        )
    }

    public static func failure(
        for request: ControlRequest,
        code: ControlErrorCode,
        message: String,
        hint: String? = nil,
        text: [String]? = nil
    ) -> ControlResponse {
        ControlResponse(
            id: request.id,
            command: request.command,
            ok: false,
            text: text,
            error: ControlErrorPayload(code: code, message: message, hint: hint)
        )
    }

    /// CLI-side failures (usage, no app) use the same envelope as server
    /// failures so agents only ever parse one shape.
    public static func localFailure(
        id: String = UUID().uuidString,
        command: String,
        code: ControlErrorCode,
        message: String,
        hint: String? = nil
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            command: command,
            ok: false,
            error: ControlErrorPayload(code: code, message: message, hint: hint)
        )
    }

    public func encodedLine(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let line = String(data: data, encoding: .utf8) else {
            return #"{"schemaVersion":1,"ok":false,"error":{"code":"failed","message":"Could not encode the response"}}"#
        }
        return line
    }

    public var exitCode: Int32 {
        if ok { return 0 }
        return error?.exitCode ?? 1
    }
}
