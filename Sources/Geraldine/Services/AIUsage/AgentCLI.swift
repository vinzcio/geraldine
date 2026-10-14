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

    /// An empty folder Geraldine owns. Usage CLIs run here, so trust or MCP
    /// decisions they record apply to Geraldine's checks, not the home folder.
    static func usageWorkspace(homeDirectory: URL) -> URL {
        let folder = homeDirectory.appendingPathComponent(
            "Library/Application Support/Geraldine/Usage Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Newline-delimited JSON-RPC over stdin/stdout. Each request goes out once
    /// the previous reply has arrived; the last reply is returned, nil on
    /// timeout or exit. Closing stdin ends the exchange, and if Geraldine quits
    /// mid-request the pipe closes and the CLI exits on EOF.
    static func exchange(executable: URL, arguments: [String], homeDirectory: URL,
                         workingDirectory: URL, requests: [(id: Int, line: String)],
                         timeout: TimeInterval) -> Data? {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment(homeDirectory: homeDirectory)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let writer = input.fileHandleForWriting.fileDescriptor
        // A CLI that exits early must not take Geraldine down with SIGPIPE.
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { return nil }
        defer { finish(process, input: input) }

        let reader = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Data()
        var reply: Data?
        for request in requests {
            guard writeAll(Data((request.line + "\n").utf8), to: writer) else { return nil }
            reply = nil
            while reply == nil {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }
                var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { return nil }
                guard ready > 0 else { continue }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let count = read(reader, &buffer, buffer.count)
                guard count > 0 else { return nil }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = pending[pending.startIndex..<newline]
                    pending = Data(pending[pending.index(after: newline)...])
                    if let object = AIUsageJSON.object(from: Data(line)),
                       AIUsageJSON.number(object["id"]) == Double(request.id) {
                        reply = Data(line)
                    }
                }
            }
        }
        return reply
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var base = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let written = write(descriptor, base, left)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                base += written
                left -= written
            }
            return true
        }
    }

    /// Close stdin, give the CLI a moment to exit on EOF, then make sure it is gone.
    private static func finish(_ process: Process, input: Pipe) {
        try? input.fileHandleForWriting.close()
        let grace = Date().addingTimeInterval(2)
        while process.isRunning && Date() < grace {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let hardStop = Date().addingTimeInterval(1)
            while process.isRunning && Date() < hardStop {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }
}

protocol ProviderUsageReading: Sendable {
    func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot
    /// Readers with several logins per home (Claude, Codex) pick one by account key.
    func snapshot(for identity: AIUsageIdentity, homeDirectory: URL, now: Date) async -> AIUsageSnapshot
}

extension ProviderUsageReading {
    func snapshot(for identity: AIUsageIdentity, homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
        await snapshot(homeDirectory: homeDirectory, now: now)
    }

    func snapshotOffMain(_ work: @escaping () -> AIUsageSnapshot) async -> AIUsageSnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}
