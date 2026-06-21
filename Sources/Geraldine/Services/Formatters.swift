import Foundation

enum Fmt {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    static func size(_ value: Double) -> String {
        // Clamp + finite-check so a NaN/∞/overflowing value can never trap Int64().
        let safe = value.isFinite ? max(0, min(value, 1e18)) : 0
        return bytes.string(fromByteCount: Int64(safe))
    }

    static func size(_ value: Int64) -> String {
        bytes.string(fromByteCount: max(0, value))
    }

    static func size(_ value: UInt64) -> String {
        bytes.string(fromByteCount: Int64(clamping: value))
    }

    static func rate(_ bytesPerSec: Double) -> String {
        let parts = rateParts(bytesPerSec)
        return "\(rateNumber(parts.value, unitIndex: parts.unitIndex)) \(parts.unit)/s"
    }

    static func compactRate(_ bytesPerSec: Double) -> String {
        let parts = rateParts(bytesPerSec)
        return "\(compactRateNumber(parts.value, unitIndex: parts.unitIndex))\(parts.compactUnit)/s"
    }

    static func percent(_ fraction: Double) -> String {
        let f = fraction.isFinite ? fraction : 0
        return "\(Int((f * 100).rounded()))%"
    }

    /// Fixed-width scaled magnitude: always 2 decimals + unit, e.g. "5.20M", "12.30K",
    /// "999.99G", "0.00B". Used for the menu bar so the item width never changes.
    static func fixedScaled(_ value: Double) -> String {
        let v = value.isFinite ? max(0, value) : 0
        let units = ["B", "K", "M", "G", "T"]
        var m = v, i = 0
        while m >= 1000, i < units.count - 1 { m /= 1000; i += 1 }
        return String(format: "%.2f", m) + units[i]
    }

    /// Very compact magnitude for the menu bar, e.g. "1.2M", "640K", "3.4G" (no unit suffix).
    static func short(_ value: Double) -> String {
        let v = value.isFinite ? max(0, value) : 0
        switch v {
        case 1_000_000_000...: return String(format: "%.1fG", v / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", v / 1_000_000)
        case 1_000...:         return String(format: "%.0fK", v / 1_000)
        default:               return String(format: "%.0f", v)
        }
    }

    private static func rateParts(_ value: Double) -> (value: Double, unit: String, compactUnit: String, unitIndex: Int) {
        let units = [("B", "B"), ("KB", "K"), ("MB", "M"), ("GB", "G"), ("TB", "T")]
        var scaled = value.isFinite ? max(0, min(value, 1e18)) : 0
        var index = 0

        while scaled >= 999.5, index < units.count - 1 {
            scaled /= 1000
            index += 1
        }

        return (scaled, units[index].0, units[index].1, index)
    }

    private static func rateNumber(_ value: Double, unitIndex: Int) -> String {
        if unitIndex == 0 {
            return "\(Int(value.rounded()))"
        }

        if value < 100 {
            return String(format: "%.1f", value)
        }

        return "\(Int(value.rounded()))"
    }

    private static func compactRateNumber(_ value: Double, unitIndex: Int) -> String {
        let value = min(value, 999)

        if unitIndex == 0 {
            return "\(Int(value.rounded()))"
        }

        if value < 9.95 {
            return String(format: "%.1f", value)
        }

        return "\(Int(value.rounded()))"
    }
}
