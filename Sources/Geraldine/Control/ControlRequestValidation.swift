import Foundation
import GeraldineControl

/// Socket clients need not use the CLI parser. Validate the normalized request
/// before resolving any live controller or starting any read/side effect.
enum ControlRequestValidation {
    static func processSampleLimit(top: Int) -> Int? {
        guard top > 0 else { return nil }
        let (count, overflow) = top.multipliedReportingOverflow(by: 2)
        return overflow ? nil : max(count, 20)
    }

    static func durationSeconds(_ raw: String) -> TimeInterval? {
        guard let seconds = Double(raw), seconds.isFinite, seconds > 0,
              Int(exactly: seconds.rounded(.up)) != nil else { return nil }
        return seconds
    }

    static func largeFileMinimumBytes(megabytes: Int) -> UInt64? {
        guard megabytes > 0, let value = UInt64(exactly: megabytes) else { return nil }
        let (bytes, overflow) = value.multipliedReportingOverflow(by: 1_000_000)
        return overflow ? nil : bytes
    }

    static func error(for request: ControlRequest) -> String? {
        guard request.protocolVersion == ControlProtocol.version else {
            return "Unsupported control protocol version."
        }
        let args = request.arguments
        let options = request.options
        let allowedOptions: Set<String>
        let validArguments: Bool
        switch request.command {
        case "awake":
            allowedOptions = args.first == "off" ? [] : ["duration"]
            validArguments = args.count == 1 && ["on", "off", "toggle"].contains(args[0])
            if let raw = options["duration"], raw != "indefinitely", durationSeconds(raw) == nil {
                return "Duration must be finite positive seconds representable by the duration display, or indefinitely."
            }
        case "stay-active":
            allowedOptions = []
            validArguments = (args.count == 1 && ["on", "off"].contains(args[0]))
                || (args.count == 2 && args[0] == "delay" && ["1", "2", "5"].contains(args[1]))
        case "settings":
            allowedOptions = []
            switch args.first {
            case "list": validArguments = args.count == 1
            case "get": validArguments = args.count == 2
            case "set": validArguments = args.count == 3
            default: validArguments = false
            }
        case "widgets":
            allowedOptions = args.first == "move" ? ["position", "before"] : []
            switch args.first {
            case "list", "reset": validArguments = args.count == 1
            case "show", "hide", "move": validArguments = args.count == 2
            case "size": validArguments = args.count == 3
            default: validArguments = false
            }
            if args.first == "move" {
                let position = options["position"] ?? "front"
                guard ["front", "before"].contains(position),
                      (position == "before") == (options["before"] != nil) else {
                    return "widgets move needs front, or before with a widget id."
                }
            }
        case "stats":
            allowedOptions = ["watch"]
            validArguments = args.count <= 1
                && (args.first.map { ["cpu", "memory", "gpu", "network", "battery", "thermal", "storage", "all"].contains($0) } ?? true)
            if let watch = options["watch"], watch != "true" { return "watch must be true when supplied." }
        case "processes":
            allowedOptions = ["top", "sort"]
            validArguments = args.isEmpty
            if let raw = options["top"], Int(raw).flatMap({ processSampleLimit(top: $0) }) == nil {
                return "top must be a positive integer with a representable sampling count."
            }
            if let sort = options["sort"], !["cpu", "memory"].contains(sort) { return "sort must be cpu or memory." }
        case "usage":
            allowedOptions = ["refresh"]
            validArguments = args.isEmpty
            if let refresh = options["refresh"], refresh != "true" { return "refresh must be true when supplied." }
        case "open":
            allowedOptions = []
            validArguments = args.count <= 1
                && (args.first.map { Module(rawValue: $0) != nil } ?? true)
        case "large-files":
            allowedOptions = ["path", "minSizeMB"]
            validArguments = args == ["scan"]
            if let raw = options["minSizeMB"], Int(raw).flatMap({ largeFileMinimumBytes(megabytes: $0) }) == nil {
                return "minSizeMB must be a positive integer representable in bytes."
            }
            if let path = options["path"], path.isEmpty || path.utf8.contains(0) { return "path must name a folder." }
        case "cleanup", "storage", "smart-care", "privacy":
            allowedOptions = []
            validArguments = args == ["scan"]
        case "uninstaller", "login-items":
            allowedOptions = []
            validArguments = args == ["list"]
        case "status", "devices", "permissions", "doctor":
            allowedOptions = []
            validArguments = args.isEmpty
        default:
            return "Unknown control command \"\(request.command)\"."
        }
        guard validArguments else { return "Invalid arguments for \(request.command)." }
        let unknown = Set(options.keys).subtracting(allowedOptions).sorted()
        guard unknown.isEmpty else { return "Unknown option(s) for \(request.command): \(unknown.joined(separator: ", "))." }
        return nil
    }
}
