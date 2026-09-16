import Foundation

enum AgentCLI {
    /// Resolve an official agent CLI without consulting PATH. Isolated tests pass a
    /// fake home, so system locations are only consulted for the real user home.
    static func executable(named name: String, homeDirectory: URL,
                           extraHomePaths: [String] = []) -> URL? {
        var candidates = extraHomePaths.map { homeDirectory.appendingPathComponent($0) }
        candidates.append(homeDirectory.appendingPathComponent(".local/bin/\(name)"))
        candidates.append(homeDirectory.appendingPathComponent(".homebrew/bin/\(name)"))
        if homeDirectory.standardizedFileURL.path == AIUsageCredentialStore.home().standardizedFileURL.path {
            candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"))
            candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(name)"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(executable: URL, arguments: [String], homeDirectory: URL,
                    stdin: Data? = nil) -> (data: Data, status: Int32) {
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = homeDirectory
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
