// Provider accounting adapted from T3 Code (MIT), revision c0f9e3618495.
// Copyright (c) 2026 T3 Tools Inc. See Resources/Licenses/T3Code.txt.
import Foundation

/// Disjoint billable categories. Reasoning is a subset of output, never added to total.
struct AIHistoryTokens: Equatable, Codable, Sendable {
    var input: Double = 0
    var cacheRead: Double = 0
    var cacheWrite: Double = 0
    var output: Double = 0
    var reasoning: Double = 0
    var total: Double { input + cacheRead + cacheWrite + output }
    mutating func add(_ other: Self) {
        input += other.input; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
        output += other.output; reasoning += other.reasoning
    }
}

struct AIHistoryRecord: Sendable {
    var model: String
    var date: Date
    var tokens: AIHistoryTokens
    var reportedCost: Double? = nil
    var speed: String = "standard"
    var keys: [String] = []
    var rateModel: String? = nil
}

struct AIHistoryRead: Sendable {
    var records: [AIHistoryRecord] = []
    var source: String
    var notice: String? = nil
}

struct AIHistoryModelTotal: Identifiable, Codable, Sendable {
    var id: String { model }
    var model: String
    var tokens = AIHistoryTokens()
    var cost: Double = 0
    var unpricedRecords = 0
    var reportedRecords = 0
    var estimatedRecords = 0
}

struct AIHistorySummary: Codable, Sendable {
    var models: [AIHistoryModelTotal]
    var source: String
    var notice: String?
    var firstDate: Date?
    var lastDate: Date?
    var updatedAt: Date
    var tokens: AIHistoryTokens {
        models.reduce(into: AIHistoryTokens()) { $0.add($1.tokens) }
    }
    var cost: Double { models.reduce(0) { $0 + $1.cost } }
    var unpricedRecords: Int { models.reduce(0) { $0 + $1.unpricedRecords } }

    init(read: AIHistoryRead, prices: AIHistoryPrices, now: Date = Date()) {
        var totals: [String: AIHistoryModelTotal] = [:]
        for record in read.records {
            var model = totals[record.model] ?? AIHistoryModelTotal(model: record.model)
            model.tokens.add(record.tokens)
            if let reported = record.reportedCost {
                model.cost += reported; model.reportedRecords += 1
            } else if let cost = prices.cost(record) {
                model.cost += cost; model.estimatedRecords += 1
            } else {
                model.unpricedRecords += 1
            }
            totals[record.model] = model
        }
        models = totals.values.sorted { $0.model < $1.model }
        source = read.source; notice = read.notice
        firstDate = read.records.map(\.date).min(); lastDate = read.records.map(\.date).max()
        updatedAt = now
    }
}

/// Public per-token rates, independent of subscription allowances and bills.
struct AIHistoryPrices: Sendable {
    struct Rate: Equatable, Sendable {
        var input: Double; var output: Double; var read: Double; var write: Double
    }
    var models: [String: [String: Rate]] = [:]
    static let url = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    init(data: Data? = nil) {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (name, raw) in json {
            guard let row = raw as? [String: Any], let standard = Self.rate(row, suffix: "") else { continue }
            var rates = ["standard": standard]
            for (speed, suffix) in [("fast", "_priority"), ("ultrafast", "_ultrafast")] {
                if let rate = Self.rate(row, suffix: suffix, standard: standard) { rates[speed] = rate }
            }
            if let specific = row["provider_specific_entry"] as? [String: Any],
               let factor = HistoryJSON.number(specific["fast"]), factor > 0 {
                rates["fast"] = Rate(input: standard.input * factor, output: standard.output * factor,
                                     read: standard.read * factor, write: standard.write * factor)
            }
            models[name.lowercased()] = rates
        }
        // Only add bare aliases when every vendor agrees on the rates.
        let grouped = Dictionary(grouping: models.keys, by: { String($0.split(separator: "/").last ?? "") })
        for (alias, names) in grouped where models[alias] == nil {
            if let first = names.first, names.allSatisfy({ models[$0] == models[first] }) { models[alias] = models[first] }
        }
    }

    private static func rate(_ row: [String: Any], suffix: String, standard: Rate? = nil) -> Rate? {
        guard let input = HistoryJSON.number(row["input_cost_per_token" + suffix]),
              let output = HistoryJSON.number(row["output_cost_per_token" + suffix]) else { return nil }
        func cache(_ key: String, base: Double?) -> Double {
            if let value = HistoryJSON.number(row[key + suffix]) { return value }
            if let base, let standard, standard.input > 0 { return base / standard.input * input }
            return input
        }
        return Rate(input: input, output: output,
                    read: cache("cache_read_input_token_cost", base: standard?.read),
                    write: cache("cache_creation_input_token_cost", base: standard?.write))
    }

    func cost(_ record: AIHistoryRecord) -> Double? {
        let key = (record.rateModel ?? record.model).trimmingCharacters(in: .whitespacesAndNewlines).lowercased().components(separatedBy: "[")[0]
        guard !["opus", "sonnet", "haiku", "fable", "grok", "<synthetic>"].contains(key),
              let tiers = models[key], let rate = tiers[record.speed] ?? tiers["standard"] else { return nil }
        let t = record.tokens
        let result = t.input * rate.input + t.output * rate.output + t.cacheRead * rate.read + t.cacheWrite * rate.write
        return result.isFinite ? result : nil
    }
}

enum HistoryJSON {
    static func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func text(_ value: Any?) -> String { value as? String ?? "" }
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
        return n.doubleValue
    }
    static func count(_ value: Any?) -> Double { floor(number(value) ?? 0) }
    static func date(_ value: Any?) -> Date? {
        if let n = number(value) { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        guard let s = value as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
            ?? (try? Date.ISO8601FormatStyle().parse(s))
    }
}
