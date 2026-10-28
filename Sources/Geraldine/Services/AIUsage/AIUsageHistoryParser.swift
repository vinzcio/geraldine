// Provider accounting adapted from T3 Code (MIT), revision c0f9e3618495.
// Copyright (c) 2026 T3 Tools Inc. See Resources/Licenses/T3Code.txt.
import Foundation

/// Only usage metadata survives parsing. Conversation text is neither retained nor logged.
struct AIHistoryParser {
    var provider: AICodingProvider
    var model = ""
    var session = ""
    var speed = "standard"
    private var cumulative: [Double]?
    private var lastSignature: [Double]?
    private var sawSession = false
    private var forkCopyDate: Date?
    var malformed = 0

    init(provider: AICodingProvider) { self.provider = provider }

    mutating func parse(_ row: [String: Any]) -> [AIHistoryRecord] {
        switch provider {
        case .claude:
            let message = HistoryJSON.object(row["message"])
            let model = HistoryJSON.text(message["model"])
            guard HistoryJSON.text(row["type"]) == "assistant", !model.isEmpty, model != "<synthetic>",
                  let date = HistoryJSON.date(row["timestamp"]), let usage = message["usage"] as? [String: Any] else { return [] }
            let id = HistoryJSON.text(message["id"]), request = HistoryJSON.text(row["requestId"])
            return [AIHistoryRecord(model: model, date: date, tokens: tokens(usage, input: "input_tokens", read: "cache_read_input_tokens", write: "cache_creation_input_tokens", output: "output_tokens"), reportedCost: HistoryJSON.number(row["costUSD"]), speed: HistoryJSON.text(usage["speed"]) == "fast" ? "fast" : "standard", keys: id.isEmpty && request.isEmpty ? [] : ["claude:\(id):\(request)"])]
        case .codex: return codex(row)
        case .grok: return grok(row)
        case .pi: return pi(row)
        case .opencode: return openCode(row)
        case .muse: return muse(row)
        case .cursor, .antigravity: return [] // API and SQLite adapters below.
        }
    }

    private func tokens(_ u: [String: Any], input: String, read: String, write: String, output: String,
                        reasoning: String = "reasoning_tokens", inclusive: Bool = false) -> AIHistoryTokens {
        let i = HistoryJSON.count(u[input]), o = HistoryJSON.count(u[output])
        let r = inclusive ? min(i, HistoryJSON.count(u[read])) : HistoryJSON.count(u[read])
        let w = inclusive ? min(i - r, HistoryJSON.count(u[write])) : HistoryJSON.count(u[write])
        return AIHistoryTokens(input: inclusive ? i - r - w : i, cacheRead: r, cacheWrite: w,
                               output: o, reasoning: min(o, HistoryJSON.count(u[reasoning])))
    }

    private mutating func codex(_ row: [String: Any]) -> [AIHistoryRecord] {
        let p = HistoryJSON.object(row["payload"]), type = HistoryJSON.text(row["type"])
        if type == "session_meta" {
            if !sawSession {
                sawSession = true; session = HistoryJSON.text(p["id"])
                let spawn = HistoryJSON.object(HistoryJSON.object(HistoryJSON.object(p["source"])["subagent"])["thread_spawn"])
                if p["forked_from_id"] is String || spawn["parent_thread_id"] is String { forkCopyDate = HistoryJSON.date(row["timestamp"]) }
            }
            return []
        }
        if type == "turn_context" {
            if let m = p["model"] as? String { model = m }
            if p["service_tier"] != nil { speed = tier(p["service_tier"]) }
            return []
        }
        if HistoryJSON.text(p["type"]) == "thread_settings_applied" {
            speed = tier(HistoryJSON.object(p["thread_settings"])["service_tier"])
            return []
        }
        guard type == "event_msg", HistoryJSON.text(p["type"]) == "token_count",
              let date = HistoryJSON.date(row["timestamp"]), !model.isEmpty else { return [] }
        let info = HistoryJSON.object(p["info"])
        let last = counters(info["last_token_usage"]), total = counters(info["total_token_usage"])
        let previous = cumulative
        if let total { cumulative = total }
        if let anchor = forkCopyDate, date.timeIntervalSince(anchor) < 1 {
            forkCopyDate = date; lastSignature = last; return []
        }
        forkCopyDate = nil
        guard let last, info["total_token_usage"] == nil || info["total_token_usage"] is NSNull || total != nil else { malformed += 1; return [] }
        guard last[0] + last[3] > 0 else { lastSignature = nil; return [] }
        if let total {
            if total == previous { return [] }
            let delta = zip(total, previous ?? Array(repeating: 0, count: last.count)).map(-)
            let validPrefix = previous == nil && zip(total, last).allSatisfy { $0 >= $1 }
            guard total == last || delta == last || validPrefix else { malformed += 1; return [] }
        } else {
            if last == lastSignature { return [] }
            cumulative = zip(previous ?? Array(repeating: 0, count: last.count), last).map(+)
        }
        lastSignature = last
        let t = AIHistoryTokens(input: last[0] - last[1] - last[2], cacheRead: last[1], cacheWrite: last[2], output: last[3], reasoning: last[4])
        return [AIHistoryRecord(model: model, date: date, tokens: t, speed: speed, keys: session.isEmpty ? [] : ["codex:\(session):\(date.timeIntervalSince1970):\(total ?? last)"])]
    }

    private func counters(_ value: Any?) -> [Double]? {
        guard let u = value as? [String: Any],
              let i = HistoryJSON.number(u["input_tokens"]), let o = HistoryJSON.number(u["output_tokens"]) else { return nil }
        let r = HistoryJSON.count(u["cached_input_tokens"]), w = HistoryJSON.count(u["cache_write_input_tokens"])
        let reasoning = HistoryJSON.count(u["reasoning_output_tokens"])
        guard r + w <= i, reasoning <= o,
              HistoryJSON.number(u["total_tokens"]) ?? (i + o) == i + o else { return nil }
        return [i, r, w, o, reasoning]
    }

    private func tier(_ raw: Any?) -> String {
        let t = HistoryJSON.text(raw)
        return ["fast", "priority"].contains(t) ? "fast" : t == "ultrafast" ? "ultrafast" : "standard"
    }

    private func grok(_ row: [String: Any]) -> [AIHistoryRecord] {
        let params = HistoryJSON.object(row["params"]), update = HistoryJSON.object(params["update"])
        guard HistoryJSON.text(update["sessionUpdate"]) == "turn_completed",
              let date = HistoryJSON.date(HistoryJSON.object(params["_meta"])["agentTimestampMs"] ?? row["timestamp"]),
              let usage = update["usage"] as? [String: Any] else { return [] }
        let models = HistoryJSON.object(usage["modelUsage"])
        let entries = models.isEmpty ? ["grok": usage] : models.compactMapValues { $0 as? [String: Any] }
        let prompt = HistoryJSON.text(update["prompt_id"]), session = HistoryJSON.text(params["sessionId"])
        var records = entries.sorted(by: { $0.key < $1.key }).map { name, u in
            AIHistoryRecord(model: name, date: date,
                tokens: tokens(u, input: "inputTokens", read: "cachedReadTokens", write: "cacheCreationTokens", output: "outputTokens", reasoning: "reasoningTokens", inclusive: true),
                reportedCost: HistoryJSON.number(u["costUsdTicks"]).map { $0 / 10_000_000_000 },
                keys: prompt.isEmpty ? [] : ["grok:\(session):\(prompt):\(name)"])
        }.filter { $0.tokens.total > 0 }
        if let cost = HistoryJSON.number(usage["costUsdTicks"]).map({ $0 / 10_000_000_000 }) {
            let remainder = max(0, cost - records.compactMap(\.reportedCost).reduce(0, +))
            let count = records.filter { $0.reportedCost == nil }.reduce(0) { $0 + $1.tokens.total }
            if count > 0 {
                for i in records.indices where records[i].reportedCost == nil { records[i].reportedCost = remainder * records[i].tokens.total / count }
            }
        }
        return records
    }

    private func pi(_ row: [String: Any]) -> [AIHistoryRecord] {
        let type = HistoryJSON.text(row["type"])
        guard ["message", "usage", "compaction", "branch_summary"].contains(type),
              let date = HistoryJSON.date(row["timestamp"]) else { return [] }
        let source = type == "message" ? HistoryJSON.object(row["message"]) : row
        if type == "message", !["assistant", "toolResult"].contains(HistoryJSON.text(source["role"])) { return [] }
        guard let usage = source["usage"] as? [String: Any] else { return [] }
        let model = HistoryJSON.text(source["responseModel"] ?? source["model"])
        let providerName = HistoryJSON.text(source["provider"])
        let name = model.isEmpty ? "Tools/summaries" : (providerName.isEmpty ? model : "\(providerName)/\(model)")
        let id = HistoryJSON.text(row["id"])
        let cost = HistoryJSON.number(HistoryJSON.object(usage["cost"])["total"])
        return [AIHistoryRecord(model: name, date: date,
            tokens: tokens(usage, input: "input", read: "cacheRead", write: "cacheWrite", output: "output", reasoning: "reasoning"),
            reportedCost: cost.flatMap { $0 > 0 ? $0 : nil },
            keys: id.isEmpty ? [] : ["pi:\(id):\(date.timeIntervalSince1970):\(name)"], rateModel: model.isEmpty ? nil : model)]
    }

    private func openCode(_ row: [String: Any]) -> [AIHistoryRecord] {
        if let role = row["role"] as? String, role != "assistant" { return [] }
        let model = HistoryJSON.object(row["model"])
        let name = HistoryJSON.text(model["id"] ?? model["modelID"] ?? row["modelID"])
        guard !name.isEmpty, let time = HistoryJSON.number(HistoryJSON.object(row["time"])["created"]),
              let usage = row["tokens"] as? [String: Any] else { return [] }
        let cache = HistoryJSON.object(usage["cache"]), reasoning = HistoryJSON.count(usage["reasoning"])
        let t = AIHistoryTokens(input: HistoryJSON.count(usage["input"]), cacheRead: HistoryJSON.count(cache["read"]), cacheWrite: HistoryJSON.count(cache["write"]), output: HistoryJSON.count(usage["output"]) + reasoning, reasoning: reasoning)
        let cost = HistoryJSON.number(row["cost"]), id = HistoryJSON.text(row["id"])
        return [AIHistoryRecord(model: name, date: Date(timeIntervalSince1970: time / 1000), tokens: t,
            reportedCost: cost.flatMap { $0 > 0 ? $0 : nil }, keys: id.isEmpty ? [] : ["opencode:\(id)"])]
    }

    private func muse(_ row: [String: Any]) -> [AIHistoryRecord] {
        let payload = HistoryJSON.object(row["payload"]), event = HistoryJSON.object(payload["event"])
        guard HistoryJSON.number(row["schema_version"]) == 1,
              HistoryJSON.text(row["record_type"]) == "event",
              HistoryJSON.text(row["payload_type"]) == "runtime.session",
              [1.0, 3.0].contains(HistoryJSON.number(row["payload_schema_version"]) ?? -1),
              ["model_completed", "automated_review_completed"].contains(HistoryJSON.text(event["kind"])),
              let time = HistoryJSON.number(row["recorded_at"]), let u = event["usage"] as? [String: Any] else { return [] }
        let name = (event["model"] as? String) ?? HistoryJSON.text(HistoryJSON.object(event["model"])["model_id"])
        guard !name.isEmpty else { return [] }
        var usage = u
        usage["cache_read_tokens"] = u["cache_read_tokens"] ?? u["cached_input_tokens"] ?? u["cached_tokens"]
        let id = HistoryJSON.text(payload["source_run_record_id"] ?? row["id"])
        return [AIHistoryRecord(model: name, date: Date(timeIntervalSince1970: time / 1_000_000),
            tokens: tokens(usage, input: "input_tokens", read: "cache_read_tokens", write: "cache_write_tokens", output: "output_tokens", inclusive: true),
            keys: id.isEmpty ? [] : ["muse:\(id)"])]
    }
}
