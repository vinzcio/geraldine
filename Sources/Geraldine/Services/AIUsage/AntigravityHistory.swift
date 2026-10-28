// Provider accounting adapted from T3 Code (MIT), revision c0f9e3618495.
// Copyright (c) 2026 T3 Tools Inc. See Resources/Licenses/T3Code.txt.
import Foundation
import SQLite3

/// Reads only generation metadata from native conversation databases, never conversation text.
enum AntigravityHistory {
    static func read(_ file: URL) throws -> [AIHistoryRecord] {
        let db = try HistoryDatabase(file)
        let tables = try db.names("SELECT name FROM sqlite_master WHERE type = 'table'")
        guard tables.contains("steps") || tables.contains("gen_metadata") else { throw HistoryReadError.invalid }
        var records: [AIHistoryRecord] = []
        var fallback = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if tables.contains("trajectory_metadata_blob") {
            try db.rows("SELECT data FROM trajectory_metadata_blob") { stmt in
                if let data = HistoryDatabase.data(stmt, 0), let date = try Proto(data).nested(2).date { fallback = date }
            }
        }
        for step in [true, false] where tables.contains(step ? "steps" : "gen_metadata") {
            let query = step ? "SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL" : "SELECT idx, data FROM gen_metadata"
            try db.rows(query) { stmt in
                guard let bytes = HistoryDatabase.data(stmt, 1) else { return }
                let idx = sqlite3_column_int64(stmt, 0)
                let root = try Proto(bytes), data = step ? root : try root.nested(1)
                let model = step ? try data.nested(24) : data
                let name = model.text(step ? 12 : 19).isEmpty ? model.text(step ? 8 : 21) : model.text(step ? 12 : 19)
                let modelID = model.number(step ? 1 : 3)
                let date = step ? (try data.nested(8).date ?? data.nested(1).date) : try data.nested(9).nested(4).date
                var usages: [Data] = data.bytes(step ? 9 : 4).map { [$0] } ?? []
                for retry in data.values[step ? 28 : 17] ?? [] {
                    if case .bytes(let bytes) = retry, let usage = try Proto(bytes).bytes(2) { usages.append(usage) }
                }
                for (index, bytes) in usages.enumerated() {
                    let u = try Proto(bytes)
                    let output = max(u.number(3), u.number(9) + u.number(10))
                    let tokens = AIHistoryTokens(input: u.number(2), cacheRead: u.number(5), cacheWrite: u.number(4), output: output, reasoning: min(output, u.number(9)))
                    let keys = [11, 12, 7].compactMap { key -> String? in
                        let id = u.text(key)
                        return id.isEmpty ? nil : "antigravity:\(key):\(id)"
                    }
                    let id = u.number(1) > 0 ? u.number(1) : modelID
                    let modelName = (id < Double(Int.max) ? knownModels[Int(id)] : nil) ?? normalize(name, id: id)
                    records.append(AIHistoryRecord(model: modelName, date: date ?? fallback, tokens: tokens,
                        keys: keys.isEmpty ? ["antigravity:\(file.deletingPathExtension().lastPathComponent):\(step):\(idx):\(index)"] : keys,
                        rateModel: modelName.replacingOccurrences(of: "-(low|medium|high)$", with: "", options: .regularExpression)))
                }
            }
        }
        return records
    }

    private static func normalize(_ name: String, id: Double) -> String {
        guard !name.isEmpty else { return "antigravity-unknown-\(String(format: "%.0f", id))" }
        let normalized = name.lowercased().replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: #"^claude-(4(?:\.\d+)?)-(sonnet|opus|haiku)"#, with: "claude-$2-$1", options: .regularExpression)
        return normalized.hasPrefix("claude-") ? normalized.replacingOccurrences(of: ".", with: "-") : normalized
    }
    // Native numeric identifiers from T3's Antigravity metadata reader. Unrecognized IDs stay unpriced.
    private static let knownModels: [Int: String] = [246: "gemini-2.5-pro", 312: "gemini-2.5-flash", 313: "gemini-2.5-flash-thinking", 329: "gemini-2.5-flash-thinking", 330: "gemini-2.5-flash-lite", 281: "claude-sonnet-4", 282: "claude-sonnet-4", 290: "claude-opus-4", 291: "claude-opus-4", 333: "claude-sonnet-4-5", 334: "claude-sonnet-4-5", 340: "claude-haiku-4-5", 341: "claude-haiku-4-5", 1026: "claude-opus-4-6", 1035: "claude-sonnet-4-6", 1016: "gemini-3.1-pro", 1036: "gemini-3.1-pro", 1037: "gemini-3.1-pro", 1018: "gemini-3-flash-preview", 1084: "gemini-3-flash-preview", 1047: "gemini-3-flash-preview"]

    struct Proto {
        enum Value { case number(UInt64), bytes(Data) }
        var values: [Int: [Value]] = [:]
        init(_ data: Data) throws {
            let bytes = [UInt8](data)
            var offset = 0
            func varint() throws -> UInt64 {
                var value: UInt64 = 0
                for shift in stride(from: 0, through: 63, by: 7) {
                    guard offset < bytes.count else { throw HistoryReadError.invalid }
                    let byte = bytes[offset]; offset += 1
                    guard shift != 63 || byte <= 1 else { throw HistoryReadError.invalid }
                    value |= UInt64(byte & 127) << shift
                    if byte < 128 { return value }
                }
                throw HistoryReadError.invalid
            }
            while offset < bytes.count {
                let tag = try varint(), field = tag >> 3, wire = tag & 7
                guard field > 0, field <= UInt64(Int.max) else { throw HistoryReadError.invalid }
                if wire == 0 { values[Int(field), default: []].append(.number(try varint())) }
                else if [1, 2, 5].contains(wire) {
                    let size = wire == 2 ? try varint() : wire == 1 ? 8 : 4
                    guard size <= UInt64(bytes.count - offset) else { throw HistoryReadError.invalid }
                    let end = offset + Int(size)
                    if wire == 2 { values[Int(field), default: []].append(.bytes(Data(bytes[offset..<end]))) }
                    offset = end
                } else { throw HistoryReadError.invalid }
            }
        }
        func number(_ field: Int) -> Double {
            if case .number(let n) = values[field]?.first { return Double(n) }
            return 0
        }
        func bytes(_ field: Int) -> Data? {
            if case .bytes(let data) = values[field]?.first { return data }
            return nil
        }
        func nested(_ field: Int) throws -> Proto { try Proto(bytes(field) ?? Data()) }
        func text(_ field: Int) -> String { bytes(field).flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        var date: Date? { number(1) > 0 ? Date(timeIntervalSince1970: number(1) + number(2) / 1e9) : nil }
    }
}
