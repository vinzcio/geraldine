// Provider accounting adapted from T3 Code (MIT), revision c0f9e3618495.
// Copyright (c) 2026 T3 Tools Inc. See Resources/Licenses/T3Code.txt.
import Foundation
import SQLite3

struct AIHistoryReader: Sendable {
    var home: URL
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func directories(_ identity: AIUsageIdentity) -> [URL] {
        func path(_ variable: String, fallback: String) -> URL {
            guard let value = environment[variable], !value.isEmpty else { return home.appendingPathComponent(fallback) }
            return expand(value)
        }
        switch identity.provider {
        case .claude, .codex:
            let name = identity.provider.rawValue
            let base = identity.accountKey.isEmpty
                ? path(name == "claude" ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME", fallback: ".\(name)")
                : home.appendingPathComponent(".\(name)-\(identity.accountKey)")
            return name == "claude" ? [base.appendingPathComponent("projects")] : [base.appendingPathComponent("sessions"), base.appendingPathComponent("archived_sessions")]
        case .grok: return [path("GROK_HOME", fallback: ".grok").appendingPathComponent("sessions")]
        case .pi:
            if let dir = environment["PI_CODING_AGENT_SESSION_DIR"], !dir.isEmpty { return [expand(dir)] }
            return [path("PI_CODING_AGENT_DIR", fallback: ".pi/agent").appendingPathComponent("sessions")]
        case .opencode:
            if let dirs = environment["OPENCODE_DATA_DIR"], !dirs.isEmpty { return dirs.split(separator: ",").map { expand(String($0)) } }
            return [path("XDG_DATA_HOME", fallback: ".local/share").appendingPathComponent("opencode")]
        case .antigravity:
            let roots = environment["ANTIGRAVITY_DATA_DIR"]?.split(separator: ",").map { expand(String($0)) }
                ?? [".gemini/antigravity", ".gemini/antigravity-cli", ".gemini/antigravity-ide", ".gemini/antigravity-backup", ".config/antigravity"].map { home.appendingPathComponent($0) }
            return roots.map { root in
                let nested = root.appendingPathComponent("conversations")
                return FileManager.default.fileExists(atPath: nested.path) ? nested : root
            }
        case .muse:
            // Muse owns discovery; callers can select a native sessions folder when the CLI is absent.
            return museHome().map { [$0.appendingPathComponent("sessions")] } ?? []
        case .cursor: return []
        }
    }

    private func expand(_ raw: String) -> URL {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }

    private func museHome() -> URL? {
        guard let executable = AgentCLI.executable(named: "muse", homeDirectory: home) else { return nil }
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"geraldine","version":"1"},"capabilities":{"requestedCapabilities":[]}}}"#
        guard let reply = AgentCLI.exchange(executable: executable,
            arguments: ["serve", "--disable-shell", "--disable-write", "--no-session-log"],
            homeDirectory: home, workingDirectory: home, requests: [(1, request)], timeout: CodexCLIUsage().timeout),
            let json = AIUsageJSON.object(from: reply),
            let path = HistoryJSON.object(json["result"])["museHome"] as? String, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    func read(_ identity: AIUsageIdentity, directory: URL? = nil) throws -> AIHistoryRead {
        let roots = directory.map { [$0] } ?? directories(identity)
        var records: [AIHistoryRecord] = [], seenPaths = Set<String>(), failures = 0, found = false
        let fm = FileManager.default
        for root in roots {
            try Task.checkCancellation()
            guard fm.fileExists(atPath: root.path) else { continue }
            found = true
            guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in failures += 1; return true }) else { failures += 1; continue }
            var candidates: [URL] = []
            for case let file as URL in files {
                try Task.checkCancellation()
                guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { failures += 1; continue }
                guard info.isSymbolicLink != true else { files.skipDescendants(); continue }
                if info.isRegularFile == true, seenPaths.insert(file.resolvingSymlinksInPath().path).inserted { candidates.append(file) }
            }
            // Native OpenCode databases take precedence over stale legacy JSON copies.
            candidates.sort {
                if ($0.pathExtension == "db") != ($1.pathExtension == "db") { return $0.pathExtension == "db" }
                return $0.path < $1.path
            }
            for file in candidates {
                try Task.checkCancellation()
                do {
                    if file.pathExtension == "db", identity.provider == .antigravity {
                        records += try AntigravityHistory.read(file)
                    } else if file.pathExtension == "db", identity.provider == .opencode, file.lastPathComponent.hasPrefix("opencode") {
                        records += try openCodeDatabase(file)
                    } else if file.pathExtension == "json", identity.provider == .opencode, file.path.contains("/storage/message/") {
                        var parser = AIHistoryParser(provider: .opencode)
                        if let row = AIUsageJSON.object(from: try Data(contentsOf: file)) { records += parser.parse(row) }
                        else { failures += 1 }
                    } else if file.pathExtension == "jsonl", identity.provider != .opencode,
                              identity.provider != .antigravity,
                              identity.provider != .grok || file.lastPathComponent == "updates.jsonl",
                              identity.provider != .muse || file.lastPathComponent == "session.jsonl" {
                        var parser = AIHistoryParser(provider: identity.provider)
                        try Self.lines(file) { line in
                            guard let row = AIUsageJSON.object(from: line) else { failures += 1; return }
                            records += parser.parse(row)
                        }
                        failures += parser.malformed
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failures += 1 }
            }
        }
        return AIHistoryRead(records: Self.deduplicate(records, merge: identity.provider == .antigravity), source: "\(identity.provider.title) local history", notice: !found ? "Local history unavailable. Choose its history folder if it is stored elsewhere." : failures > 0 ? "Partial history: \(failures) unreadable or invalid records/sources were skipped." : nil)
    }

    static func lines(_ file: URL, consume: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var buffer = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 10) {
                if newline > start { try consume(Data(buffer[start..<newline])) }
                start = buffer.index(after: newline)
            }
            if start > buffer.startIndex { buffer = Data(buffer[start...]) }
        }
        // An incomplete live append is retried on refresh, never treated as a zero-usage event.
        if !buffer.isEmpty, AIUsageJSON.object(from: buffer) != nil { try consume(buffer) }
    }

    static func deduplicate(_ input: [AIHistoryRecord], merge: Bool = false) -> [AIHistoryRecord] {
        var records: [Int: AIHistoryRecord] = [:], owners: [String: Int] = [:]
        var nextID = 0
        for record in input where record.tokens.total > 0 || record.reportedCost != nil {
            let matches = Set(record.keys.compactMap { owners[$0] }).sorted()
            let owner = matches.first ?? nextID
            nextID += 1
            if matches.isEmpty { records[owner] = record }
            else if merge {
                var merged = record
                for key in matches {
                    guard let old = records.removeValue(forKey: key) else { continue }
                    merged.keys += old.keys
                    merged.date = min(merged.date, old.date)
                    merged.tokens = AIHistoryTokens(input: max(merged.tokens.input, old.tokens.input), cacheRead: max(merged.tokens.cacheRead, old.tokens.cacheRead), cacheWrite: max(merged.tokens.cacheWrite, old.tokens.cacheWrite), output: max(merged.tokens.output, old.tokens.output), reasoning: max(merged.tokens.reasoning, old.tokens.reasoning))
                    if merged.model.contains("unknown") { merged.model = old.model; merged.rateModel = old.rateModel }
                }
                records[owner] = merged
            }
            for key in records[owner]?.keys ?? [] { owners[key] = owner }
        }
        return records.sorted { $0.key < $1.key }.map(\.value)
    }

    private func openCodeDatabase(_ file: URL) throws -> [AIHistoryRecord] {
        let db = try HistoryDatabase(file)
        var parser = AIHistoryParser(provider: .opencode), records: [AIHistoryRecord] = []
        let tables = try db.names("SELECT name FROM sqlite_master WHERE type = 'table'")
        guard tables.contains("message") || tables.contains("session_message") else { throw HistoryReadError.invalid }
        for table in ["message", "session_message"] where tables.contains(table) {
            let columns = try db.names("SELECT name FROM pragma_table_info('\(table)')")
            let time = columns.contains("time_created") ? "time_created" : "NULL"
            let filter = table == "session_message" ? " WHERE type = 'assistant'" : ""
            try db.rows("SELECT id, data, \(time) FROM \(table)\(filter)") { statement in
                guard let data = HistoryDatabase.data(statement, 1), var row = AIUsageJSON.object(from: data) else { throw HistoryReadError.invalid }
                if row["id"] == nil { row["id"] = HistoryDatabase.string(statement, 0) }
                if row["time"] == nil, sqlite3_column_type(statement, 2) != SQLITE_NULL { row["time"] = ["created": sqlite3_column_double(statement, 2)] }
                records += parser.parse(row)
            }
        }
        return records
    }
}

enum HistoryReadError: Error { case invalid }

final class HistoryDatabase {
    private var db: OpaquePointer?
    init(_ file: URL) throws {
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw HistoryReadError.invalid
        }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw HistoryReadError.invalid
        }
    }
    deinit {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        sqlite3_close(db)
    }
    func rows(_ query: String, consume: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw HistoryReadError.invalid }
        defer { sqlite3_finalize(statement) }
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw HistoryReadError.invalid }
            try consume(statement)
        }
    }
    func names(_ query: String) throws -> Set<String> {
        var names = Set<String>()
        try rows(query) { if let name = Self.string($0, 0) { names.insert(name) } }
        return names
    }
    static func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
    static func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
