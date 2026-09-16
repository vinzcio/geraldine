import Foundation

protocol AntigravityUsageReading: Sendable {
    func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot
}

/// Only agy's built-in usage command owns authentication and quota fetching.
/// Never inspect desktop processes, copy tokens, or send a model prompt.
struct AntigravityCLIUsage: AntigravityUsageReading {
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
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return .failed(.antigravity, message: "Could not run Antigravity CLI usage.")
        }
        // Drain before waiting: subprocess output must not block on a full pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .failed(.antigravity, message: AICodingProvider.antigravity.usageUnavailableHint)
        }
        switch Self.parse(data, now: now) {
        case .success(let snapshot): return snapshot
        case .failure(let error): return .failed(.antigravity, message: error.message)
        }
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
        for group in groups {
            guard let group = AIUsageJSON.dictionary(group),
                  let buckets = AIUsageJSON.array(group["buckets"]) else { continue }
            for bucket in buckets {
                guard let bucket = AIUsageJSON.dictionary(bucket),
                      let id = AIUsageJSON.string(bucket["id"]), let title = titles[id],
                      let fraction = AIUsageJSON.number(bucket["remaining_fraction"]),
                      fraction.isFinite, (0...1).contains(fraction) else { continue }
                windows[id] = AIUsageWindow(id: id, title: title, usedPercent: (1 - fraction) * 100,
                                            resetsAt: AIUsageJSON.date(bucket["reset_time"]))
            }
        }
        let ordered = ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"].compactMap { windows[$0] }
        guard ordered.count == 4 else {
            return .failure(.init(message: "Antigravity CLI did not return all four quota windows."))
        }
        return .success(AIUsageSnapshot(provider: .antigravity, status: .ready, plan: nil,
                                        windows: ordered, fetchedAt: now, sourceLabel: "Antigravity CLI"))
    }
}
