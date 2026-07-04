import Foundation

struct BuildInfo {
    static let current = BuildInfo(bundle: .main)

    let version: String
    let bundleVersion: String
    let commit: String
    let shortCommit: String
    let isDirty: Bool
    let builtAt: String
    let configuration: String

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        version = Self.stringValue("CFBundleShortVersionString", in: info, fallback: "Unknown")
        bundleVersion = Self.stringValue("CFBundleVersion", in: info, fallback: version)
        commit = Self.stringValue("GeraldineBuildCommit", in: info, fallback: "unknown")
        shortCommit = Self.stringValue("GeraldineBuildCommitShort",
                                       in: info,
                                       fallback: String(commit.prefix(12)))
        isDirty = Self.boolValue("GeraldineBuildDirty", in: info)
        builtAt = Self.stringValue("GeraldineBuildDate", in: info, fallback: "Unknown")
        configuration = Self.stringValue("GeraldineBuildConfiguration", in: info, fallback: "Unknown")
    }

    var versionLabel: String {
        if bundleVersion == version {
            return "Version \(version)"
        }
        return "Version \(version) (\(bundleVersion))"
    }

    var revisionLabel: String {
        guard shortCommit != "unknown", !shortCommit.isEmpty else { return "Unknown" }
        return isDirty ? "\(shortCommit)-dirty" : shortCommit
    }

    private static func stringValue(_ key: String, in info: [String: Any], fallback: String) -> String {
        guard let value = info[key] as? String else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func boolValue(_ key: String, in info: [String: Any]) -> Bool {
        if let value = info[key] as? Bool { return value }
        if let value = info[key] as? String { return value == "true" || value == "1" }
        return false
    }
}
