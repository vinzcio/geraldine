import Darwin
import Foundation

/// Static hardware identity for the Mac running Geraldine.
struct HardwareInfo: Sendable {
    var modelName: String
    var modelIdentifier: String?

    var displayName: String { modelName.isEmpty ? "Mac" : modelName }
    var isPortable: Bool { modelName.localizedCaseInsensitiveContains("MacBook") }

    static let current = HardwareInfo.detect()

    private static func detect() -> HardwareInfo {
        let identifier = sysctlString("hw.model")
        let name = systemProfilerModelName() ?? fallbackModelName(for: identifier)
        return HardwareInfo(modelName: name, modelIdentifier: identifier)
    }

    private static func systemProfilerModelName() -> String? {
        let result = Shell.run("/usr/sbin/system_profiler", ["SPHardwareDataType"])
        guard result.status == 0 else { return nil }

        for raw in result.output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Model Name:") else { continue }
            let name = line.dropFirst("Model Name:".count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private static func fallbackModelName(for identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return "Mac" }
        if identifier.localizedCaseInsensitiveContains("MacBook") { return "MacBook" }
        if identifier.localizedCaseInsensitiveContains("iMac") { return "iMac" }
        if identifier.localizedCaseInsensitiveContains("Macmini") { return "Mac mini" }
        if identifier.localizedCaseInsensitiveContains("MacPro") { return "Mac Pro" }
        if identifier.localizedCaseInsensitiveContains("MacStudio") { return "Mac Studio" }
        return "Mac"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }

        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
