import Foundation
import Darwin

/// Reads helper provenance without loading the app or looking at its settings.
/// An unbundled debug binary has no verified app-build identity.
struct CLIDiagnostics {
    let checks: [DoctorCheck]
    let fields: [String: JSONValue]
    let identityMismatch: Bool

    init(executableURL: URL?, installedAppURL: URL?, environment: [String: String], appIdentity: JSONValue?) {
        let executable = executableURL?.resolvingSymlinksInPath().standardizedFileURL
        let onPath = Self.executableOnPATH(environment: environment)
        let bundle = executable.flatMap(Self.bundledIdentity)
        let match = Self.compare(bundle: bundle, app: appIdentity)
        identityMismatch = match == "mismatch"

        var isDirectory: ObjCBool = false
        let installed = installedAppURL.map {
            FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
        } ?? false
        let currentOnPATH = onPath != nil && onPath?.resolvingSymlinksInPath().standardizedFileURL == executable
        let pathDetail: String
        if let onPath {
            pathDetail = "PATH resolves geraldine to \(onPath.path)."
                + (currentOnPATH ? " It is this helper." : " It could not be matched to this helper.")
        } else {
            pathDetail = "No executable geraldine resolves on the supplied PATH. Run `geraldine install-cli` and add its directory to PATH."
        }
        let identityDetail: String
        switch match {
        case "match": identityDetail = "The helper's containing app metadata matches the responding app's version, build, revision, configuration, and build date."
        case "mismatch": identityDetail = "The helper's containing app metadata differs from the responding app; update the helper/app together."
        default: identityDetail = "Build identity is unknown: both containing-app metadata and a responding app's complete identity are required. An unbundled debug helper cannot prove a match."
        }
        checks = [
            DoctorCheck(name: "Installed app", status: installed ? "ok" : "warn", detail: installed
                ? "An app directory exists at \(installedAppURL!.path); installation presence does not prove it is the responding process."
                : "No app directory was found at the configured installation path."),
            DoctorCheck(name: "CLI on PATH", status: currentOnPATH ? "ok" : "warn", detail: pathDetail),
            DoctorCheck(name: "CLI/app identity", status: match == "match" ? "ok" : match == "mismatch" ? "fail" : "warn", detail: identityDetail)
        ]
        fields = [
            "appInstalled": .bool(installed),
            "installedAppPath": installedAppURL.map { .string($0.path) } ?? .null,
            "cliAppIdentityMatch": .string(match),
            "cli": .object([
                "version": .string(CommandCatalog.version),
                "executable": executable.map { .string($0.path) } ?? .null,
                "pathOnPATH": onPath.map { .string($0.path) } ?? .null,
                "currentHelperOnPATH": .bool(currentOnPATH),
                "bundle": bundle.map(JSONValue.object) ?? .null
            ])
        ]
    }

    static func executableOnPATH(environment: [String: String]) -> URL? {
        guard let path = environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(fileURLWithPath: directory.isEmpty ? "." : String(directory), isDirectory: true)
                .appendingPathComponent("geraldine")
            var info = stat()
            if stat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    private static func bundledIdentity(_ executable: URL) -> [String: JSONValue]? {
        let helpers = executable.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard executable.lastPathComponent == "geraldine", helpers.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents", app.pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == SettingsCatalog.suiteName else { return nil }
        func string(_ key: String) -> JSONValue {
            guard let value = plist[key] as? String else { return .null }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.lowercased() != "unknown" else { return .null }
            return .string(trimmed)
        }
        let dirty: JSONValue
        if let value = plist["GeraldineBuildDirty"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
            dirty = .bool(value.boolValue)
        } else if let value = plist["GeraldineBuildDirty"] as? String, ["true", "false", "1", "0"].contains(value) {
            dirty = .bool(value == "true" || value == "1")
        } else {
            dirty = .null
        }
        return [
            "path": .string(app.path),
            "version": string("CFBundleShortVersionString"),
            "build": string("CFBundleVersion"),
            "commit": string("GeraldineBuildCommit"),
            "shortCommit": string("GeraldineBuildCommitShort"),
            "isDirty": dirty,
            "builtAt": string("GeraldineBuildDate"),
            "configuration": string("GeraldineBuildConfiguration")
        ]
    }

    private static func compare(bundle: [String: JSONValue]?, app: JSONValue?) -> String {
        guard let bundle, let app = app?.objectValue else { return "unknown" }
        var complete = true
        for key in ["version", "build", "commit", "isDirty", "builtAt", "configuration"] {
            guard let local = bundle[key], local != .null, let remote = app[key], remote != .null,
                  remote.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "unknown",
                  remote.stringValue != "" else {
                complete = false
                continue
            }
            if local != remote { return "mismatch" }
        }
        return complete ? "match" : "unknown"
    }
}
