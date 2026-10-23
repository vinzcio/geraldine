import Foundation

public enum AwakeDuration: Equatable, Sendable {
    case indefinite
    case seconds(TimeInterval)
}

public enum DurationParserError: Error, LocalizedError, Equatable {
    case empty
    case invalid(String)
    case tooLong

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "A duration is required."
        case .invalid(let value):
            return "\"\(value)\" is not a duration. Use forms like 90m, 2h, 1h30m, 45s, or indefinitely."
        case .tooLong:
            return "Durations longer than 30 days are not supported."
        }
    }
}

public enum DurationParser {
    public static let maximumSeconds: TimeInterval = 30 * 24 * 60 * 60

    /// Accepts `indefinitely`, `forever`, `infinite`, `∞`, bare minutes
    /// (`90`), and compound units (`1h30m`, `2 hours`, `1.5h`, `45s`).
    public static func parse(_ raw: String) throws -> AwakeDuration {
        let text = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { throw DurationParserError.empty }
        if ["indefinitely", "indefinite", "forever", "infinite", "∞", "none"].contains(text) {
            return .indefinite
        }

        var index = text.startIndex
        var total: TimeInterval = 0
        var matched = false

        while index < text.endIndex {
            let numberStart = index
            var sawDigit = false
            var sawDot = false
            while index < text.endIndex {
                let character = text[index]
                if character.isNumber {
                    sawDigit = true
                    index = text.index(after: index)
                } else if character == ".", !sawDot {
                    sawDot = true
                    index = text.index(after: index)
                } else {
                    break
                }
            }
            guard sawDigit, let value = Double(text[numberStart..<index]), value.isFinite, value >= 0 else {
                throw DurationParserError.invalid(raw)
            }

            let unitStart = index
            while index < text.endIndex, text[index].isLetter {
                index = text.index(after: index)
            }
            let unit = String(text[unitStart..<index])
            let multiplier: TimeInterval
            switch unit {
            case "", "m", "min", "mins", "minute", "minutes":
                multiplier = 60
            case "h", "hr", "hrs", "hour", "hours":
                multiplier = 60 * 60
            case "s", "sec", "secs", "second", "seconds":
                multiplier = 1
            case "d", "day", "days":
                multiplier = 24 * 60 * 60
            default:
                throw DurationParserError.invalid(raw)
            }
            total += value * multiplier
            matched = true
        }

        guard matched else { throw DurationParserError.invalid(raw) }
        guard total >= 1 else { throw DurationParserError.invalid(raw) }
        guard total <= maximumSeconds else { throw DurationParserError.tooLong }
        return .seconds(total)
    }

    public static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if days > 0 { return minutes > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(days)d \(hours)h" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return remainder > 0 ? "\(minutes)m \(remainder)s" : "\(minutes)m" }
        return "\(remainder)s"
    }
}
