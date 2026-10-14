import Darwin
import Foundation

protocol AntigravityUsageReading: Sendable {
    func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot
}

/// Only agy's built-in usage command owns authentication and quota fetching.
/// Never inspect desktop processes, copy tokens, or send a model prompt.
struct AntigravityCLIUsage: AntigravityUsageReading {
    /// agy can wait a minute for its eligibility check and spend about another
    /// retrying a failing quota request, so a slow answer is normal. A check
    /// still running after this is stuck, and would hold up every tile's refresh.
    var timeout: TimeInterval = 150

    func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: read(homeDirectory: homeDirectory, now: now))
            }
        }
    }

    private func read(homeDirectory: URL, now: Date) -> AIUsageSnapshot {
        let candidates = [
            homeDirectory.appendingPathComponent(".local/bin/agy"),
            homeDirectory.appendingPathComponent(".homebrew/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy")
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return .failed(.antigravity, message: "Antigravity CLI (agy) was not found.")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--print", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = homeDirectory
        process.environment = AgentCLI.environment(homeDirectory: homeDirectory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return .failed(.antigravity, message: "Could not run Antigravity CLI usage.")
        }
        let deadline = Date().addingTimeInterval(timeout)
        let data = Self.output(of: process, from: output, until: deadline)
        guard Self.exited(process, by: deadline) else {
            return .failed(.antigravity, message: "Antigravity CLI did not answer within \(Int(timeout)) seconds.")
        }
        guard process.terminationStatus == 0 else {
            return .failed(.antigravity,
                           message: Self.failureMessage(data) ?? AICodingProvider.antigravity.usageUnavailableHint)
        }
        switch Self.parse(data, now: now) {
        case .success(let snapshot): return snapshot
        case .failure(let error): return .failed(.antigravity, message: error.message)
        }
    }

    /// What agy prints before it exits or the deadline passes. poll() bounds
    /// every wait, and once agy has exited, a helper that inherited its stdout
    /// cannot hold the read open.
    private static func output(of process: Process, from pipe: Pipe, until deadline: Date) -> Data {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&state, 1, Int32(min(remaining, 0.25) * 1000))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { break }
            guard ready > 0 else {
                if process.isRunning { continue }
                break
            }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// Waits for agy to exit by the deadline. One still running then is
    /// stopped (SIGTERM, then SIGKILL after two seconds) and reaped.
    private static func exited(_ process: Process, by deadline: Date) -> Bool {
        while process.isRunning && Date() < deadline { usleep(50_000) }
        guard process.isRunning else { return true }
        process.terminate()
        let grace = Date().addingTimeInterval(2)
        while process.isRunning && Date() < grace { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        return false
    }

    /// agy reports a failed check as JSON on stdout and exits 1:
    /// {"status":"ERROR","error":"/usage failed: …: UNAVAILABLE (code 503): The service is currently unavailable."}
    /// Name what went wrong. Running /usage by hand hits the same server.
    static func failureMessage(_ data: Data) -> String? {
        guard let json = AIUsageJSON.object(from: data),
              AIUsageJSON.string(json["status"]) == "ERROR",
              let error = AIUsageJSON.string(json["error"]) else { return nil }
        if let code = error.range(of: #"(?<=\(code )\d{3}(?=\))"#, options: .regularExpression).map({ error[$0] }) {
            return code == "503"
                ? "Antigravity's server is unavailable (HTTP 503)."
                : "Antigravity's server returned an error (HTTP \(code))."
        }
        if error.contains("dial tcp") || error.contains("no such host") {
            return "Antigravity CLI could not reach its server."
        }
        return "Antigravity CLI: \(error)"
    }

    static func parse(_ data: Data, now: Date) -> Result<AIUsageSnapshot, AIUsageParseError> {
        guard let json = AIUsageJSON.object(from: data),
              AIUsageJSON.string(json["status"]) == "SUCCESS",
              AIUsageJSON.number(json["num_turns"]) == 0,
              let command = AIUsageJSON.dictionary(json["command"]),
              AIUsageJSON.string(command["name"]) == "usage",
              let payload = AIUsageJSON.dictionary(command["data"]),
              let groups = AIUsageJSON.array(payload["groups"]) else {
            return .failure(.init(message: "Antigravity CLI did not return structured usage. Run agy /usage and retry."))
        }
        let titles = [
            "gemini-weekly": "Gemini · Weekly",
            "gemini-5h": "Gemini · 5-hour",
            "3p-weekly": "Claude/GPT · Weekly",
            "3p-5h": "Claude/GPT · 5-hour"
        ]
        var windows: [String: AIUsageWindow] = [:]
        var disabled = Set<String>()
        for group in groups {
            guard let group = AIUsageJSON.dictionary(group),
                  let buckets = AIUsageJSON.array(group["buckets"]) else { continue }
            for bucket in buckets {
                guard let bucket = AIUsageJSON.dictionary(bucket),
                      let id = AIUsageJSON.string(bucket["id"]), let title = titles[id] else { continue }
                // Once a group's weekly limit is spent, agy turns its 5-hour
                // limit off ("does not currently apply") yet still sends
                // remaining_fraction 1. That is not quota left, so draw no row.
                if bucket["disabled"] as? Bool == true {
                    disabled.insert(id)
                    continue
                }
                guard let fraction = AIUsageJSON.number(bucket["remaining_fraction"]),
                      fraction.isFinite, (0...1).contains(fraction) else { continue }
                // reset_time is ISO; any other reset field ("Resets in 106h4m42s") is a fallback.
                let reset = AIUsageJSON.date(bucket["reset_time"]).map { AIUsageResetParser.Reset(date: $0, dateOnly: false) }
                    ?? AIUsageResetParser.reset(in: bucket, now: now)
                windows[id] = AIUsageWindow(id: id, title: title, usedPercent: (1 - fraction) * 100,
                                            resetsAt: reset?.date, resetIsDateOnly: reset?.dateOnly ?? false)
            }
        }
        let ids = ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"]
        guard ids.allSatisfy({ windows[$0] != nil || disabled.contains($0) }) else {
            return .failure(.init(message: "Antigravity CLI did not return all four quota windows."))
        }
        return .success(AIUsageSnapshot(provider: .antigravity, status: .ready, plan: nil,
                                        windows: ids.compactMap { windows[$0] }, fetchedAt: now,
                                        sourceLabel: "Antigravity CLI"))
    }
}
