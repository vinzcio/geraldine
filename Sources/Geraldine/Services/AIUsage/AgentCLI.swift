import Foundation

enum AgentCLI {
    /// Resolve an official agent CLI without consulting PATH. Isolated tests pass a
    /// fake home, so system locations are only consulted for the real user home.
    static func executable(named name: String, homeDirectory: URL,
                           extraHomePaths: [String] = []) -> URL? {
        let candidates = extraHomePaths.map { homeDirectory.appendingPathComponent($0) }
            + binDirectories(homeDirectory: homeDirectory).map { $0.appendingPathComponent(name) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Menu-bar apps inherit `/usr/bin:/bin:/usr/sbin:/sbin`. Codex is
    /// `#!/usr/bin/env node` with node in `~/.local/bin`, so usage launches
    /// must put the CLI install directories ahead of that GUI PATH.
    static func environment(homeDirectory: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let prepend = binDirectories(homeDirectory: homeDirectory).map(\.path).filter {
            !existing.contains($0) && FileManager.default.fileExists(atPath: $0)
        }
        env["PATH"] = (prepend + existing).joined(separator: ":")
        return env
    }

    private static func binDirectories(homeDirectory: URL) -> [URL] {
        var directories = [
            homeDirectory.appendingPathComponent(".local/bin"),
            homeDirectory.appendingPathComponent(".homebrew/bin")
        ]
        if homeDirectory.standardizedFileURL.path == AIUsageCredentialStore.home().standardizedFileURL.path {
            directories.append(URL(fileURLWithPath: "/opt/homebrew/bin"))
            directories.append(URL(fileURLWithPath: "/usr/local/bin"))
        }
        return directories
    }

    static func run(executable: URL, arguments: [String], homeDirectory: URL,
                    stdin: Data? = nil,
                    environment: [String: String]? = nil) -> (data: Data, status: Int32) {
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = homeDirectory
        process.environment = environment ?? self.environment(homeDirectory: homeDirectory)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return (Data(), -1)
        }
        if let stdin {
            input.fileHandleForWriting.write(stdin)
        }
        input.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }
}

protocol ProviderUsageReading: Sendable {
    func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot
}

extension ProviderUsageReading {
    func snapshotOffMain(_ work: @escaping () -> AIUsageSnapshot) async -> AIUsageSnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}
