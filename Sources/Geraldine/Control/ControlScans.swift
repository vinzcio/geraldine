import Foundation
import GeraldineControl

enum ControlScanError: Error, LocalizedError {
    case pathNotFound(String)
    case notADirectory(String)
    case invalidMinimumSize

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let path): return "No folder exists at \(path)."
        case .notADirectory(let path): return "\(path) is not a folder."
        case .invalidMinimumSize: return "Minimum size must be positive whole megabytes representable in bytes."
        }
    }
}

struct ControlAppRow: Sendable {
    var name: String
    var bundleID: String
    var version: String
    var bytes: UInt64
    var path: String
    var protectedReason: String?
}

struct ControlAppList: Sendable {
    var apps: [ControlAppRow]
    var diagnostics: ControlScanDiagnostics
    var scannedItems: Int
}

struct ControlLaunchRow: Sendable {
    var label: String
    var name: String
    var program: String
    var plistPath: String
    var scope: String
    var enabled: Bool
    var editable: Bool
}

struct ControlStorageCategory: Sendable {
    var label: String
    var detail: String
    var bytes: UInt64
    var measured: Bool
}

struct ControlStorageReport: Sendable {
    var totalBytes: UInt64
    var freeBytes: UInt64
    var categories: [ControlStorageCategory]

    var usedBytes: UInt64 { totalBytes >= freeBytes ? totalBytes - freeBytes : 0 }

    var json: JSONValue {
        .object([
            "capacity": .object([
                "totalBytes": ControlJSON.bytes(totalBytes),
                "usedBytes": ControlJSON.bytes(usedBytes),
                "freeBytes": ControlJSON.bytes(freeBytes),
                "usedPercent": ControlJSON.number(
                    totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0
                )
            ]),
            "categories": .array(categories.map { category in
                .object([
                    "label": .string(category.label),
                    "detail": .string(category.detail),
                    "bytes": ControlJSON.bytes(category.bytes),
                    "confidence": .string(category.measured ? "measured" : "estimated")
                ])
            })
        ])
    }

    var humanLines: [String] {
        let usedPercent = totalBytes > 0
            ? Int((Double(usedBytes) / Double(totalBytes) * 100).rounded())
            : 0
        var lines = [
            "Startup volume: \(ControlFormat.size(totalBytes)) total, "
                + "\(ControlFormat.size(freeBytes)) free (\(usedPercent)% used)."
        ]
        for category in categories {
            let confidence = category.measured ? "measured" : "estimated"
            lines.append("  \(category.label) — \(ControlFormat.size(category.bytes)) (\(confidence))")
        }
        lines.append("Read-only measurement. Nothing was deleted or moved.")
        return lines
    }
}

struct ControlSmartCareReport: Sendable {
    var score: Int
    var findings: [ControlFinding]
    var diskFree: UInt64
    var diskTotal: UInt64
    var memoryFraction: Double
    var junk: UInt64
    var startupItems: Int

    var json: JSONValue {
        .object([
            "score": .int(score),
            "findings": .array(findings.map(\.json)),
            "vitals": .object([
                "diskFreeBytes": ControlJSON.bytes(diskFree),
                "diskTotalBytes": ControlJSON.bytes(diskTotal),
                "diskUsedPercent": ControlJSON.number(
                    diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) * 100 : 0
                ),
                "memoryUsedPercent": ControlJSON.number(memoryFraction * 100),
                "reviewableJunkBytes": ControlJSON.bytes(junk),
                "userLaunchAgents": .int(startupItems)
            ])
        ])
    }

    var humanLines: [String] {
        var lines = ["Mac health: \(score)/100"]
        for finding in findings {
            lines.append("  [\(finding.severity.uppercased())] \(finding.title) — \(finding.detail)")
        }
        lines.append("Read-only check. Open the named module to review any action.")
        return lines
    }
}

@MainActor
enum ControlScans {
    static func cleanup() async -> ControlScanReport {
        let report = await CleanupViewModel.buildGroups { _ in }
        return ControlScanReport.report(report)
    }

    static func privacy() async -> ControlScanReport {
        await Task.detached(priority: .userInitiated) {
            ControlScanReport.report(PrivacyViewModel.buildGroups())
        }.value
    }

    static func largeFiles(path: String?, minSizeMB: Int?) async throws -> ControlScanReport {
        let megabytes = minSizeMB ?? 100
        guard let minBytes = ControlRequestValidation.largeFileMinimumBytes(megabytes: megabytes) else {
            throw ControlScanError.invalidMinimumSize
        }
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        let root = path.map(expand) ?? defaultRoot
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw ControlScanError.pathNotFound(root.path)
        }
        guard isDirectory.boolValue else {
            throw ControlScanError.notADirectory(root.path)
        }
        var report = await Task.detached(priority: .userInitiated) {
            ControlScanReport.report(LargeFilesViewModel.scan(root: root, minBytes: minBytes))
        }.value
        report.scannedItems = report.diagnostics.scannedItems
        report.extra["root"] = .string(root.path)
        report.extra["minSizeMB"] = .int(megabytes)
        return report
    }

    static func storage() async throws -> ControlStorageReport {
        guard let measurement = await StorageViewModel.measureForControl() else {
            throw ControlScanError.pathNotFound("the startup volume")
        }
        return ControlStorageReport(
            totalBytes: ControlJSON.uint64(measurement.capacity.total),
            freeBytes: ControlJSON.uint64(measurement.capacity.free),
            categories: measurement.categories.map { category in
                ControlStorageCategory(
                    label: category.label,
                    detail: category.detail,
                    bytes: ControlJSON.uint64(category.value),
                    measured: category.confidence == .measured
                )
            }
        )
    }

    static func smartCare() async -> ControlSmartCareReport {
        let monitor = AppState.shared.monitor
        let diskTotal = monitor.diskTotal
        let diskFree = max(0, diskTotal - monitor.diskUsed)
        let memoryFraction = monitor.memoryFraction
        let extras = await SmartCareViewModel.gather()
        let evaluation = SmartCareViewModel.evaluate(
            diskFraction: monitor.diskFraction,
            memFraction: memoryFraction,
            diskTotal: diskTotal,
            diskFree: diskFree,
            extras: extras
        )
        return ControlSmartCareReport(
            score: evaluation.score,
            findings: evaluation.findings.map(ControlFinding.from),
            diskFree: ControlJSON.uint64(diskFree),
            diskTotal: ControlJSON.uint64(diskTotal),
            memoryFraction: memoryFraction,
            junk: extras.junk,
            startupItems: extras.startupItems
        )
    }

    static func uninstaller() async -> ControlAppList {
        let discovery = await Task.detached(priority: .userInitiated) {
            let found = UninstallerViewModel.discover()
            return ControlAppList(
                apps: found.apps.map { app in
                    ControlAppRow(
                        name: app.name,
                        bundleID: app.bundleID,
                        version: app.version,
                        bytes: app.size,
                        path: app.url.path,
                        protectedReason: app.protectedReason
                    )
                },
                diagnostics: ControlScanDiagnostics(found.diagnostics),
                scannedItems: found.diagnostics.scannedItems
            )
        }.value
        return discovery
    }

    static func loginItems() async -> (items: [ControlLaunchRow], diagnostics: ControlScanDiagnostics) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userAgents = home.appendingPathComponent("Library/LaunchAgents")
        let disabled = home.appendingPathComponent("Library/Application Support/Geraldine/DisabledLaunchAgents")
        let result = await Task.detached(priority: .userInitiated) {
            LoginItemsViewModel.scan(sources: [
                LoginItemsScanSource(directory: userAgents, scope: .user, enabled: true),
                LoginItemsScanSource(directory: disabled, scope: .user, enabled: false),
                LoginItemsScanSource(directory: URL(fileURLWithPath: "/Library/LaunchAgents"), scope: .global, enabled: true),
                LoginItemsScanSource(directory: URL(fileURLWithPath: "/Library/LaunchDaemons"), scope: .daemon, enabled: true)
            ])
        }.value
        return (
            result.items.map { item in
                ControlLaunchRow(
                    label: item.label,
                    name: item.displayName,
                    program: item.program,
                    plistPath: item.plistURL.path,
                    scope: item.scope.rawValue,
                    enabled: item.enabled,
                    editable: item.editable
                )
            },
            ControlScanDiagnostics(result.diagnostics)
        )
    }

    static func appListJSON(_ list: ControlAppList) -> (result: JSONValue, text: [String]) {
        var result: [String: JSONValue] = [
            "apps": .array(list.apps.map { app in
                .object([
                    "name": .string(app.name),
                    "bundleID": .string(app.bundleID),
                    "version": .string(app.version),
                    "bytes": ControlJSON.bytes(app.bytes),
                    "path": .string(app.path),
                    "protected": .bool(app.protectedReason != nil),
                    "protectedReason": app.protectedReason.map { .string($0) } ?? .null
                ])
            }),
            "count": .int(list.apps.count),
            "scannedItems": .int(list.scannedItems),
            "diagnostics": .object([
                "skippedTotal": .int(list.diagnostics.skippedTotal),
                "skipped": .array(list.diagnostics.skipped.map { .string($0) }),
                "failure": list.diagnostics.failure.map { .string($0) } ?? .null
            ])
        ]
        result["totalBytes"] = ControlJSON.bytes(list.apps.reduce(0) { $0 + $1.bytes })
        var lines = [
            "\(list.apps.count) applications, "
                + "\(ControlFormat.size(list.apps.reduce(0) { $0 + $1.bytes })) total."
        ]
        for app in list.apps.prefix(20) {
            let suffix = app.protectedReason.map { " (protected: \($0))" } ?? ""
            lines.append("  \(app.name) — \(ControlFormat.size(app.bytes))\(suffix)")
        }
        if list.apps.count > 20 {
            lines.append("  …and \(list.apps.count - 20) more; use --json for the full list.")
        }
        if list.diagnostics.skippedTotal > 0 {
            lines.append("Skipped \(list.diagnostics.skippedTotal) unreadable path\(list.diagnostics.skippedTotal == 1 ? "" : "s").")
        }
        lines.append("Read-only list. Nothing was uninstalled.")
        return (.object(result), lines)
    }

    static func loginItemsJSON(
        _ items: [ControlLaunchRow],
        diagnostics: ControlScanDiagnostics
    ) -> (result: JSONValue, text: [String]) {
        let result = JSONValue.object([
            "items": .array(items.map { item in
                .object([
                    "label": .string(item.label),
                    "name": .string(item.name),
                    "program": .string(item.program),
                    "plistPath": .string(item.plistPath),
                    "scope": .string(item.scope),
                    "enabled": .bool(item.enabled),
                    "editable": .bool(item.editable)
                ])
            }),
            "count": .int(items.count),
            "diagnostics": .object([
                "skippedTotal": .int(diagnostics.skippedTotal),
                "skipped": .array(diagnostics.skipped.map { .string($0) }),
                "failure": diagnostics.failure.map { .string($0) } ?? .null
            ])
        ])
        var lines = ["\(items.count) launch items."]
        for item in items.prefix(25) {
            let state = item.enabled ? "on" : "off"
            lines.append("  [\(state)] \(item.name) — \(item.label) (\(item.scope))")
        }
        if items.count > 25 {
            lines.append("  …and \(items.count - 25) more; use --json for the full list.")
        }
        lines.append("Read-only list. No launchd state was changed.")
        return (result, lines)
    }

    private static func expand(_ path: String) -> URL {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }
}
