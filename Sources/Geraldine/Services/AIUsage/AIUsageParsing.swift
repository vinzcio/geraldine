import Foundation

enum AIUsageJSON {
    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String, let double = Double(string) { return double }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func date(_ value: Any?) -> Date? {
        if let number = number(value) {
            let seconds = number > 10_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = string(value) else { return nil }
        if let date = iso8601Fractional.date(from: string) { return date }
        if let date = iso8601.date(from: string) { return date }
        let normalized = string.replacingOccurrences(of: "Z", with: "+00:00")
        return iso8601Fractional.date(from: normalized) ?? iso8601.date(from: normalized)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum AIUsageParser {
    static func claude(from data: Data, now: Date = Date()) -> Result<AIUsageSnapshot, AIUsageParseError> {
        guard let json = AIUsageJSON.object(from: data) else {
            return .failure(AIUsageParseError(message: "Claude usage response was not JSON."))
        }
        let keys = [
            "seven_day",
            "seven_day_overage_included",
            "seven_day_fable",
            "five_hour",
            "seven_day_sonnet",
            "seven_day_opus"
        ]
        let titles = [
            "seven_day": "All models",
            "seven_day_overage_included": "Fable",
            "seven_day_fable": "Fable",
            "five_hour": "5-hour",
            "seven_day_sonnet": "Sonnet",
            "seven_day_opus": "Opus"
        ]
        var windows: [AIUsageWindow] = []
        var seen = Set<String>()
        func appendWindow(id: String, title: String, bucket: [String: Any]) {
            guard !seen.contains(id),
                  let used = AIUsageJSON.number(bucket["utilization"])
                    ?? AIUsageJSON.number(bucket["percent"]) else { return }
            seen.insert(id)
            windows.append(AIUsageWindow(
                id: id,
                title: title,
                usedPercent: AIUsageMath.percent(from: used),
                resetsAt: AIUsageJSON.date(bucket["resets_at"])
            ))
        }
        for key in keys {
            guard let bucket = AIUsageJSON.dictionary(json[key]) else { continue }
            appendWindow(id: key, title: titles[key] ?? key, bucket: bucket)
        }
        for (key, value) in json {
            let lowered = key.lowercased()
            guard lowered.contains("fable"),
                  let bucket = AIUsageJSON.dictionary(value) else { continue }
            appendWindow(id: key, title: "Fable", bucket: bucket)
        }
        if let limits = AIUsageJSON.array(json["limits"]) {
            for (index, limit) in limits.enumerated() {
                guard let object = AIUsageJSON.dictionary(limit) else { continue }
                let scope = AIUsageJSON.dictionary(object["scope"]) ?? [:]
                let model = AIUsageJSON.dictionary(scope["model"]) ?? [:]
                let name = AIUsageJSON.string(model["display_name"])
                    ?? AIUsageJSON.string(model["id"])
                    ?? AIUsageJSON.string(scope["model"])
                    ?? AIUsageJSON.string(object["display_name"])
                guard let name, name.lowercased().contains("fable") else { continue }
                let bucket = AIUsageJSON.dictionary(object["window"]) ?? object
                appendWindow(id: "limit-fable-\(index)", title: "Fable", bucket: bucket)
            }
        }
        if windows.isEmpty {
            return .failure(AIUsageParseError(message: "Claude did not return any usage windows."))
        }
        let plan = AIUsageJSON.string(json["subscription_type"])
            ?? AIUsageJSON.string(json["rate_limit_tier"])
        return .success(AIUsageSnapshot(
            provider: .claude,
            status: .ready,
            plan: plan,
            windows: windows,
            fetchedAt: now,
            sourceLabel: "Anthropic usage"
        ))
    }

    static func codex(from data: Data, now: Date = Date()) -> Result<AIUsageSnapshot, AIUsageParseError> {
        guard let json = AIUsageJSON.object(from: data) else {
            return .failure(AIUsageParseError(message: "Codex usage response was not JSON."))
        }
        let rate = AIUsageJSON.dictionary(json["rate_limit"]) ?? json
        var windows: [AIUsageWindow] = []
        if let primary = window(from: rate["primary_window"], id: "primary", title: "Session") {
            windows.append(primary)
        }
        if let secondary = window(from: rate["secondary_window"], id: "secondary", title: "Weekly") {
            windows.append(secondary)
        }
        if let extras = AIUsageJSON.array(rate["additional_rate_limits"]) {
            for (index, extra) in extras.enumerated() {
                guard let object = AIUsageJSON.dictionary(extra) else { continue }
                let name = AIUsageJSON.string(object["name"])
                    ?? AIUsageJSON.string(object["id"])
                    ?? "Model \(index + 1)"
                if let nested = window(from: object["primary_window"],
                                       id: "extra-\(index)-primary",
                                       title: name) {
                    windows.append(nested)
                } else if let nested = window(from: object["secondary_window"],
                                              id: "extra-\(index)-secondary",
                                              title: name) {
                    windows.append(nested)
                } else if let nested = window(from: object, id: "extra-\(index)", title: name) {
                    windows.append(nested)
                }
            }
        }
        if windows.isEmpty {
            return .failure(AIUsageParseError(message: "Codex did not return any usage windows."))
        }
        let plan = AIUsageJSON.string(json["plan_type"])
            ?? AIUsageJSON.string(json["plan"])
        return .success(AIUsageSnapshot(
            provider: .codex,
            status: .ready,
            plan: plan,
            windows: windows,
            fetchedAt: now,
            sourceLabel: "Codex usage"
        ))
    }

    static func grok(from billing: Data, user: Data? = nil, now: Date = Date()) -> Result<AIUsageSnapshot, AIUsageParseError> {
        guard let json = AIUsageJSON.object(from: billing) else {
            return .failure(AIUsageParseError(message: "Grok billing response was not JSON."))
        }
        let config = AIUsageJSON.dictionary(json["config"]) ?? json
        guard let used = AIUsageJSON.number(config["creditUsagePercent"])
                ?? AIUsageJSON.number(config["usagePercent"]) else {
            return .failure(AIUsageParseError(message: "Grok did not return a usage percent."))
        }
        let period = AIUsageJSON.dictionary(config["currentPeriod"]) ?? [:]
        let periodType = (AIUsageJSON.string(period["type"]) ?? "Weekly")
            .replacingOccurrences(of: "USAGE_PERIOD_TYPE_", with: "")
            .capitalized
        let reset = AIUsageJSON.date(period["end"])
            ?? AIUsageJSON.date(config["billingPeriodEnd"])
        var windows = [
            AIUsageWindow(
                id: "pool",
                title: periodType.isEmpty ? "Weekly" : periodType,
                usedPercent: AIUsageMath.percent(from: used),
                resetsAt: reset
            )
        ]
        if let products = AIUsageJSON.array(config["productUsage"]) {
            for (index, product) in products.enumerated() {
                guard let object = AIUsageJSON.dictionary(product),
                      let percent = AIUsageJSON.number(object["usagePercent"]) else { continue }
                let name = AIUsageJSON.string(object["product"]) ?? "Product \(index + 1)"
                windows.append(AIUsageWindow(
                    id: "product-\(index)",
                    title: name.capitalized,
                    usedPercent: AIUsageMath.percent(from: percent),
                    resetsAt: reset
                ))
            }
        }
        var plan: String?
        if let userData = user, let userJSON = AIUsageJSON.object(from: userData) {
            plan = AIUsageJSON.string(userJSON["subscriptionTier"])
        }
        return .success(AIUsageSnapshot(
            provider: .grok,
            status: .ready,
            plan: plan,
            windows: windows,
            fetchedAt: now,
            sourceLabel: "Grok usage"
        ))
    }

    static func cursor(from data: Data, now: Date = Date()) -> Result<AIUsageSnapshot, AIUsageParseError> {
        guard let json = AIUsageJSON.object(from: data) else {
            return .failure(AIUsageParseError(message: "Cursor usage response was not JSON."))
        }
        let planUsage = AIUsageJSON.dictionary(json["planUsage"])
            ?? AIUsageJSON.dictionary(json["individualUsage"])
            ?? json
        let reset = AIUsageJSON.date(planUsage["resetDate"])
            ?? AIUsageJSON.date(planUsage["billingCycleEnd"])
            ?? AIUsageJSON.date(json["billingCycleEnd"])
            ?? AIUsageJSON.date(json["nextReset"])
        let plan = AIUsageJSON.string(json["membershipType"])
            ?? AIUsageJSON.string(json["planName"])
            ?? AIUsageJSON.string(json["membership"])
        var windows: [AIUsageWindow] = []
        let namedPercents: [(String, String)] = [
            ("autoPercentUsed", "Cursor models"),
            ("apiPercentUsed", "Other models"),
            ("totalPercentUsed", "Included")
        ]
        for (key, title) in namedPercents {
            guard let used = AIUsageJSON.number(planUsage[key]) ?? AIUsageJSON.number(json[key]) else { continue }
            windows.append(AIUsageWindow(
                id: key,
                title: title,
                usedPercent: AIUsageMath.percent(from: used),
                resetsAt: reset
            ))
        }
        if windows.isEmpty, let remaining = percentRemaining(in: planUsage) ?? percentRemaining(in: json) {
            windows.append(AIUsageWindow(
                id: "included",
                title: "Included",
                usedPercent: AIUsageMath.clampPercent(100 - remaining),
                resetsAt: reset
            ))
        }
        if !windows.isEmpty {
            return .success(AIUsageSnapshot(
                provider: .cursor,
                status: .ready,
                plan: plan,
                windows: windows,
                fetchedAt: now,
                sourceLabel: "Cursor usage"
            ))
        }
        if let models = AIUsageJSON.dictionary(json["modelUsage"])
            ?? AIUsageJSON.dictionary(json) {
            var windows: [AIUsageWindow] = []
            for (key, value) in models {
                guard let bucket = AIUsageJSON.dictionary(value) else { continue }
                let usedCount = AIUsageJSON.number(bucket["numRequests"])
                    ?? AIUsageJSON.number(bucket["used"])
                let limit = AIUsageJSON.number(bucket["maxRequestUsage"])
                    ?? AIUsageJSON.number(bucket["limit"])
                guard let usedCount, let limit, limit > 0 else { continue }
                windows.append(AIUsageWindow(
                    id: key,
                    title: key,
                    usedPercent: AIUsageMath.clampPercent((usedCount / limit) * 100),
                    resetsAt: AIUsageJSON.date(bucket["resetDate"])
                ))
            }
            if !windows.isEmpty {
                return .success(AIUsageSnapshot(
                    provider: .cursor,
                    status: .ready,
                    plan: AIUsageJSON.string(json["membershipType"]),
                    windows: windows.sorted { $0.title < $1.title },
                    fetchedAt: now,
                    sourceLabel: "Cursor usage"
                ))
            }
        }
        return .failure(AIUsageParseError(message: "Cursor did not return included usage."))
    }

    static func antigravity(from data: Data, now: Date = Date()) -> Result<AIUsageSnapshot, AIUsageParseError> {
        guard let json = AIUsageJSON.object(from: data) else {
            return .failure(AIUsageParseError(message: "Antigravity usage response was not JSON."))
        }
        var windows: [AIUsageWindow] = []

        if let credits = AIUsageJSON.number(json["availablePromptCredits"]),
           let monthly = AIUsageJSON.number(
                AIUsageJSON.dictionary(json["planInfo"])?["monthlyPromptCredits"]
                ?? json["monthlyPromptCredits"]
           ),
           monthly > 0 {
            windows.append(AIUsageWindow(
                id: "prompts",
                title: "Prompt credits",
                usedPercent: AIUsageMath.clampPercent((1 - credits / monthly) * 100),
                resetsAt: AIUsageJSON.date(json["resetTime"])
            ))
        }

        let models = AIUsageJSON.dictionary(json["models"])
            ?? AIUsageJSON.dictionary(AIUsageJSON.dictionary(json["userStatus"])?["models"])
            ?? AIUsageJSON.dictionary(AIUsageJSON.dictionary(json["quotaInfo"])?["models"])
        if let models {
            for (key, value) in models {
                guard let object = AIUsageJSON.dictionary(value) else { continue }
                let quota = AIUsageJSON.dictionary(object["quotaInfo"]) ?? object
                let remainingFraction = AIUsageJSON.number(quota["remainingFraction"])
                    ?? AIUsageJSON.number(quota["remaining_fraction"])
                let remainingPercent = AIUsageJSON.number(quota["remainingPercent"])
                let usedPercent: Double
                if let remainingFraction {
                    usedPercent = AIUsageMath.clampPercent(100 - remainingFraction * 100)
                } else if let remainingPercent {
                    usedPercent = AIUsageMath.clampPercent(100 - remainingPercent)
                } else if let used = AIUsageJSON.number(quota["usedPercent"]) {
                    usedPercent = AIUsageMath.percent(from: used)
                } else {
                    continue
                }
                let title = AIUsageJSON.string(object["displayName"])
                    ?? AIUsageJSON.string(object["label"])
                    ?? key
                windows.append(AIUsageWindow(
                    id: key,
                    title: title,
                    usedPercent: usedPercent,
                    resetsAt: AIUsageJSON.date(quota["resetTime"]) ?? AIUsageJSON.date(quota["reset_time"])
                ))
            }
        }

        if let buckets = AIUsageJSON.array(json["quotaSummaries"])
            ?? AIUsageJSON.array(json["quotas"]) {
            for (index, bucket) in buckets.enumerated() {
                guard let object = AIUsageJSON.dictionary(bucket) else { continue }
                let remainingFraction = AIUsageJSON.number(object["remainingFraction"])
                let remainingPercent = AIUsageJSON.number(object["remainingPercent"])
                let usedPercent: Double
                if let remainingFraction {
                    usedPercent = AIUsageMath.clampPercent(100 - remainingFraction * 100)
                } else if let remainingPercent {
                    usedPercent = AIUsageMath.clampPercent(100 - remainingPercent)
                } else if let used = AIUsageJSON.number(object["usedPercent"]) {
                    usedPercent = AIUsageMath.percent(from: used)
                } else {
                    continue
                }
                windows.append(AIUsageWindow(
                    id: AIUsageJSON.string(object["id"]) ?? "quota-\(index)",
                    title: AIUsageJSON.string(object["displayName"])
                        ?? AIUsageJSON.string(object["name"])
                        ?? "Quota \(index + 1)",
                    usedPercent: usedPercent,
                    resetsAt: AIUsageJSON.date(object["resetTime"])
                ))
            }
        }

        if windows.isEmpty {
            return .failure(AIUsageParseError(message: "Antigravity did not return any quota windows."))
        }
        let plan = AIUsageJSON.string(AIUsageJSON.dictionary(json["planInfo"])?["planType"])
            ?? AIUsageJSON.string(AIUsageJSON.dictionary(json["currentTier"])?["name"])
            ?? AIUsageJSON.string(json["planType"])
        return .success(AIUsageSnapshot(
            provider: .antigravity,
            status: .ready,
            plan: plan,
            windows: windows.sorted { $0.remainingPercent < $1.remainingPercent },
            fetchedAt: now,
            sourceLabel: "Antigravity quota"
        ))
    }

    private static func window(from raw: Any?, id: String, title: String) -> AIUsageWindow? {
        guard let object = AIUsageJSON.dictionary(raw) else { return nil }
        guard let used = AIUsageJSON.number(object["used_percent"])
                ?? AIUsageJSON.number(object["usedPercent"]) else { return nil }
        let reset = AIUsageJSON.date(object["reset_at"])
            ?? AIUsageJSON.date(object["resets_at"])
            ?? {
                if let seconds = AIUsageJSON.number(object["reset_after_seconds"]) {
                    return Date().addingTimeInterval(seconds)
                }
                return nil
            }()
        return AIUsageWindow(
            id: id,
            title: AIUsageJSON.string(object["name"]) ?? title,
            usedPercent: AIUsageMath.percent(from: used),
            resetsAt: reset
        )
    }

    private static func percentRemaining(in object: [String: Any]) -> Double? {
        if let remaining = AIUsageJSON.number(object["remainingPercent"])
            ?? AIUsageJSON.number(object["remaining_percent"]) {
            return AIUsageMath.percent(from: remaining)
        }
        if let usedPercent = AIUsageJSON.number(object["totalPercentUsed"])
            ?? AIUsageJSON.number(object["usedPercent"])
            ?? AIUsageJSON.number(object["percentUsed"]) {
            return AIUsageMath.clampPercent(100 - AIUsageMath.percent(from: usedPercent))
        }
        if let remaining = AIUsageJSON.number(object["remaining"]),
           let limit = AIUsageJSON.number(object["limit"]) ?? AIUsageJSON.number(object["totalSpendLimit"]),
           limit > 0 {
            return AIUsageMath.clampPercent((remaining / limit) * 100)
        }
        if let used = AIUsageJSON.number(object["used"]) ?? AIUsageJSON.number(object["totalSpend"]),
           let limit = AIUsageJSON.number(object["limit"]) ?? AIUsageJSON.number(object["includedSpendLimit"]),
           limit > 0, used <= limit {
            return AIUsageMath.clampPercent((1 - used / limit) * 100)
        }
        return nil
    }
}
