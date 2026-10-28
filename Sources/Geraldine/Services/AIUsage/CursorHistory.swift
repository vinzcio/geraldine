// Provider accounting adapted from T3 Code (MIT), revision c0f9e3618495.
// Copyright (c) 2026 T3 Tools Inc. See Resources/Licenses/T3Code.txt.
import Foundation

/// Credentials are used only at the Cursor dashboard endpoint. Redirects and shared cookies are disabled.
final class HistoryHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func data(_ request: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw HistoryReadError.invalid }
        return data
    }
}

struct CursorHistory {
    static let endpoint = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    var fetch: (URLRequest) async throws -> Data = { try await HistoryHTTP().data($0) }

    static func fileToken(home: URL) -> String? {
        for path in [".config/cursor/auth.json", ".cursor/auth.json"] {
            guard let data = try? Data(contentsOf: home.appendingPathComponent(path)), let row = AIUsageJSON.object(from: data) else { continue }
            let token = HistoryJSON.text(row["accessToken"] ?? row["access_token"] ?? row["token"])
            if !token.isEmpty { return token }
        }
        return nil
    }

    func read(home: URL, now: Date = Date()) async throws -> AIHistoryRead {
        guard let token = Self.fileToken(home: home) else {
            return AIHistoryRead(source: "Cursor account history", notice: "Cursor history needs an existing file-based CLI login. Keychain is not accessed.")
        }
        let pieces = token.split(separator: ".")
        guard pieces.count == 3 else { throw HistoryReadError.invalid }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let json = AIUsageJSON.object(from: data),
              let subject = json["sub"] as? String, let user = subject.split(separator: "|").last, !user.isEmpty,
              let cookie = "\(user)::\(token)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw HistoryReadError.invalid }
        var pages: [[[String: Any]]] = [], total: Int?, page = 1, rawCount = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["page": page, "pageSize": 1000, "startDate": "0", "endDate": String(Int64(now.timeIntervalSince1970 * 1000))])
            guard let body = AIUsageJSON.object(from: try await fetch(request)), body["error"] == nil, body["message"] == nil else { throw HistoryReadError.invalid }
            if let value = body["totalUsageEventsCount"] {
                guard let n = HistoryJSON.number(value), n.rounded() == n, n < Double(Int.max), total == nil || total == Int(n) else { throw HistoryReadError.invalid }
                total = Int(n)
            }
            let events: [[String: Any]]
            if body.isEmpty || (body.count == 1 && total == 0) { events = [] }
            else if let rows = body["usageEventsDisplay"] as? [[String: Any]] { events = rows }
            else { throw HistoryReadError.invalid }
            if events.count == 1000, let previous = pages.last,
               try Self.canonical(previous) == Self.canonical(events) { throw HistoryReadError.invalid }
            pages.append(events); rawCount += events.count
            if events.count < 1000 { break }
            page += 1
        }
        guard total == nil || rawCount >= total! else { throw HistoryReadError.invalid }
        var extra = total.map { rawCount - $0 } ?? 0, previous: [Data] = [], records: [AIHistoryRecord] = []
        for events in pages {
            let keys = try events.map { try Self.canonical($0) }
            var overlap = 0
            if extra > 0 {
                for count in 1...max(1, min(previous.count, keys.count, extra)) {
                    if count <= previous.count, count <= keys.count, Array(previous.suffix(count)) == Array(keys.prefix(count)) { overlap = count }
                }
            }
            extra -= overlap; previous = keys
            for row in events.dropFirst(overlap) {
                guard let usage = row["tokenUsage"] as? [String: Any] else { continue }
                for key in ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "totalCents"] where usage[key] != nil {
                    guard HistoryJSON.number(usage[key]) != nil else { throw HistoryReadError.invalid }
                }
                let time = (row["timestamp"] as? String).flatMap(Double.init) ?? HistoryJSON.number(row["timestamp"])
                let model = HistoryJSON.text(row["model"])
                guard let time, time.isFinite, time >= 0, !model.isEmpty else { throw HistoryReadError.invalid }
                guard time <= now.timeIntervalSince1970 * 1000 else { continue }
                records.append(AIHistoryRecord(model: model, date: Date(timeIntervalSince1970: time / 1000),
                    tokens: AIHistoryTokens(input: HistoryJSON.count(usage["inputTokens"]), cacheRead: HistoryJSON.count(usage["cacheReadTokens"]), cacheWrite: HistoryJSON.count(usage["cacheWriteTokens"]), output: HistoryJSON.count(usage["outputTokens"])),
                    reportedCost: HistoryJSON.number(usage["totalCents"]).map { $0 / 100 },
                    rateModel: Self.rateModel(model)))
            }
        }
        guard extra == 0 else { throw HistoryReadError.invalid }
        return AIHistoryRead(records: records, source: "Cursor dashboard · account-wide across machines")
    }
    static func rateModel(_ model: String) -> String {
        let base = model.replacingOccurrences(of: "^cursor-", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?:-thinking)?(?:-(?:none|minimal|low|medium|high|xhigh|max))?(?:-fast)?$", with: "", options: .regularExpression)
        return base.hasPrefix("grok-") ? "xai/" + base : base
    }
    private static func canonical(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
}
