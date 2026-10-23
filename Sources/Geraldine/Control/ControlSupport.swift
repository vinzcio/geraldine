import Foundation
import GeraldineControl
import IOKit.pwr_mgt

// MARK: - JSON helpers

/// One JSON representation for every control response. Doubles are sanitized
/// because JSONEncoder throws on NaN and infinity, and live metrics can
/// legitimately arrive empty before the first sample.
enum ControlJSON {
    static func number(_ value: Double) -> JSONValue {
        value.isFinite ? .double(value) : .null
    }

    static func optionalNumber(_ value: Double?) -> JSONValue {
        guard let value, value.isFinite else { return .null }
        return .double(value)
    }

    static func bytes(_ value: UInt64) -> JSONValue {
        .int(Int(clamping: value))
    }

    /// Safe Double → UInt64 for live measurements. Never traps on NaN or an
    /// out-of-range value; those become zero.
    static func uint64(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return UInt64(min(value, 1e18))
    }

    static func date(_ value: Date?) -> JSONValue {
        guard let value else { return .null }
        return .string(ControlFormat.iso(value))
    }

    static func date(_ value: Date) -> JSONValue {
        .string(ControlFormat.iso(value))
    }
}

enum ControlFormat {
    private static let isoFormatter = ISO8601DateFormatter()

    static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    static func size(_ bytes: UInt64) -> String {
        Fmt.size(bytes)
    }

    static func percent(_ fraction: Double) -> String {
        Fmt.percent(fraction)
    }

    static func remaining(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "indefinitely" }
        return DurationParser.format(seconds)
    }

    static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}

// MARK: - Power assertions

/// A read-only view of Geraldine's own IOPM assertions. The API is queried on
/// demand, never polled, so the control surface adds no idle wakeups.
struct PowerAssertionSnapshot {
    var available: Bool
    var idleSleep: Bool
    var displaySleep: Bool
    var names: [String]

    static let unavailable = PowerAssertionSnapshot(
        available: false, idleSleep: false, displaySleep: false, names: []
    )

    var count: Int { names.count }

    static func current(pid: pid_t = getpid()) -> PowerAssertionSnapshot {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dictionary = raw?.takeRetainedValue() as NSDictionary? else {
            return .unavailable
        }

        var names: [String] = []
        var idleSleep = false
        var displaySleep = false
        var matchedProcess = false

        for (key, value) in dictionary {
            let owner: pid_t?
            if let number = key as? NSNumber {
                owner = number.int32Value
            } else if let text = key as? String {
                owner = Int32(text)
            } else {
                owner = nil
            }
            guard owner == pid else { continue }
            matchedProcess = true

            let list = (value as? [[String: Any]])
                ?? (value as? NSArray)?.compactMap { $0 as? [String: Any] }
                ?? []
            for assertion in list {
                let name = assertion["AssertName"] as? String
                    ?? assertion[kIOPMAssertionNameKey as String] as? String
                    ?? ""
                guard name == "Geraldine Keep Awake" else { continue }
                names.append(name)
                let type = assertion["AssertType"] as? String
                    ?? assertion[kIOPMAssertionTypeKey as String] as? String
                    ?? ""
                if type == (kIOPMAssertionTypeNoIdleSleep as String) {
                    idleSleep = true
                } else if type == (kIOPMAssertionTypePreventUserIdleDisplaySleep as String) {
                    displaySleep = true
                }
            }
        }

        // No entry for this process is a valid empty result once the API has
        // succeeded; only an API failure is "unavailable".
        return PowerAssertionSnapshot(
            available: true,
            idleSleep: idleSleep,
            displaySleep: displaySleep,
            names: names
        )
    }

    var json: JSONValue {
        .object([
            "available": .bool(available),
            "systemSleepPrevented": .bool(idleSleep),
            "displaySleepPrevented": .bool(displaySleep),
            "assertionCount": .int(count)
        ])
    }

    var humanLine: String {
        guard available else { return "Power assertions: unavailable" }
        guard count > 0 else { return "Power assertions: none held" }
        var parts: [String] = []
        if idleSleep { parts.append("system sleep prevented") }
        if displaySleep { parts.append("display sleep prevented") }
        if parts.isEmpty { parts.append("\(count) held") }
        return "Power assertions: " + parts.joined(separator: ", ")
    }
}

// MARK: - Scan wire types

/// Sendable mirrors of the live scan models. Heavy scans finish on a background
/// task, then the main actor formats and serializes these values.
struct ControlScanItem: Sendable {
    var name: String
    var path: String
    var detail: String
    var bytes: UInt64
}

struct ControlScanGroup: Sendable {
    var title: String
    var itemCount: Int
    var totalBytes: UInt64
    var safeByDefault: Bool
    var items: [ControlScanItem]
}

struct ControlScanDiagnostics: Sendable {
    var scannedItems: Int
    var skippedTotal: Int
    var skipped: [String]
    var failure: String?
    var cancelled: Bool
    var finishedAt: Date?

    init(_ diagnostics: ScanDiagnostics) {
        scannedItems = diagnostics.scannedItems
        skippedTotal = diagnostics.skippedTotal
        skipped = diagnostics.skipped.prefix(10).map { issue in
            "\(issue.path): \(issue.message)"
        }
        failure = diagnostics.failure
        cancelled = diagnostics.cancelled
        finishedAt = diagnostics.finishedAt
    }
}

struct ControlScanReport: Sendable {
    var groups: [ControlScanGroup]
    var diagnostics: ControlScanDiagnostics
    var scannedItems: Int?
    var extra: [String: JSONValue] = [:]

    var totalBytes: UInt64 { groups.reduce(0) { $0 + $1.totalBytes } }
    var totalItems: Int { groups.reduce(0) { $0 + $1.itemCount } }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "groups": .array(groups.map { group in
                .object([
                    "title": .string(group.title),
                    "itemCount": .int(group.itemCount),
                    "totalBytes": ControlJSON.bytes(group.totalBytes),
                    "safeByDefault": .bool(group.safeByDefault),
                    "items": .array(group.items.map { item in
                        .object([
                            "name": .string(item.name),
                            "path": .string(item.path),
                            "detail": .string(item.detail),
                            "bytes": ControlJSON.bytes(item.bytes)
                        ])
                    })
                ])
            }),
            "totals": .object([
                "bytes": ControlJSON.bytes(totalBytes),
                "items": .int(totalItems)
            ]),
            "diagnostics": .object([
                "scannedItems": .int(diagnostics.scannedItems),
                "skippedTotal": .int(diagnostics.skippedTotal),
                "skipped": .array(diagnostics.skipped.map { .string($0) }),
                "failure": diagnostics.failure.map { .string($0) } ?? .null,
                "cancelled": .bool(diagnostics.cancelled),
                "finishedAt": ControlJSON.date(diagnostics.finishedAt)
            ])
        ]
        if let scannedItems {
            object["scannedItems"] = .int(scannedItems)
        }
        for (key, value) in extra {
            object[key] = value
        }
        return .object(object)
    }

    func humanLines(title: String) -> [String] {
        var lines = [
            "\(title): \(groups.count) group\(groups.count == 1 ? "" : "s"), "
                + "\(ControlFormat.size(totalBytes)) across \(totalItems) item\(totalItems == 1 ? "" : "s")."
        ]
        for group in groups {
            lines.append("  \(group.title) — \(ControlFormat.size(group.totalBytes)), \(group.itemCount) item\(group.itemCount == 1 ? "" : "s")")
            for item in group.items.prefix(3) {
                lines.append("    \(item.name) — \(ControlFormat.size(item.bytes))")
            }
        }
        if let failure = diagnostics.failure {
            lines.append("Scan failed: \(failure)")
        }
        if diagnostics.cancelled {
            lines.append("Scan was cancelled; results may be incomplete.")
        }
        if diagnostics.skippedTotal > 0 {
            lines.append("Skipped \(diagnostics.skippedTotal) unreadable path\(diagnostics.skippedTotal == 1 ? "" : "s"). Grant Full Disk Access for complete results.")
        }
        lines.append("Read-only scan. Nothing was deleted or moved.")
        return lines
    }

    static func group(_ group: ScanGroup, itemLimit: Int = 50) -> ControlScanGroup {
        ControlScanGroup(
            title: group.title,
            itemCount: group.items.count,
            totalBytes: group.totalSize,
            safeByDefault: group.safeByDefault,
            items: group.items.prefix(itemLimit).map { item in
                ControlScanItem(
                    name: item.name,
                    path: item.url.path,
                    detail: item.detail,
                    bytes: item.size
                )
            }
        )
    }

    static func report(_ report: ScanReport) -> ControlScanReport {
        ControlScanReport(
            groups: report.groups.map { group($0) },
            diagnostics: ControlScanDiagnostics(report.diagnostics)
        )
    }
}

// MARK: - Findings

struct ControlFinding: Sendable {
    var title: String
    var detail: String
    var scope: String
    var confidence: String
    var severity: String
    var module: String?
    var actionTitle: String?

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "title": .string(title),
            "detail": .string(detail),
            "scope": .string(scope),
            "confidence": .string(confidence),
            "severity": .string(severity),
            "actionable": .bool(module != nil && severity != "good")
        ]
        object["module"] = module.map { .string($0) } ?? .null
        object["actionTitle"] = actionTitle.map { .string($0) } ?? .null
        return .object(object)
    }

    static func from(_ finding: Finding) -> ControlFinding {
        let confidence: String
        switch finding.confidence {
        case .high: confidence = "high"
        case .medium: confidence = "medium"
        case .limited: confidence = "limited"
        }
        let severity: String
        switch finding.severity {
        case .good: severity = "good"
        case .warn: severity = "warn"
        case .bad: severity = "bad"
        }
        return ControlFinding(
            title: finding.title,
            detail: finding.detail,
            scope: finding.scope,
            confidence: confidence,
            severity: severity,
            module: finding.module?.rawValue,
            actionTitle: finding.actionTitle
        )
    }
}
