import Darwin
import Foundation

/// Drive an official agent TUI just long enough to run a local slash command.
/// The child owns authentication; Geraldine only types the command and reads
/// the screen. Process-group cleanup must not leak a leftover TUI.
enum AgentPTY {
    struct Step: Sendable {
        var afterContaining: String?
        var afterSeconds: TimeInterval
        var write: Data
    }

    static func capture(
        executable: URL,
        arguments: [String],
        homeDirectory: URL,
        environment: [String: String] = [:],
        replyColorQuery: Bool = false,
        steps: [Step],
        stopContaining: [String],
        abortContaining: [String] = [],
        timeout: TimeInterval
    ) -> String {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let slaveName = String(cString: ptsname(master), encoding: .utf8) else {
            if master >= 0 { close(master) }
            return ""
        }
        let slave = open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            return ""
        }
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        _ = ioctl(slave, TIOCSWINSZ, &size)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = homeDirectory
        process.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        var env = AgentCLI.environment(homeDirectory: homeDirectory)
        env.removeValue(forKey: "NO_COLOR")
        env.removeValue(forKey: "CI")
        env["COLUMNS"] = "120"
        env["LINES"] = "40"
        env["TERM"] = env["TERM"].flatMap { $0.isEmpty ? nil : $0 } ?? "xterm-256color"
        env["COLORTERM"] = env["COLORTERM"] ?? "truecolor"
        environment.forEach { env[$0.key] = $0.value }
        process.environment = env
        do { try process.run() } catch {
            close(slave)
            close(master)
            return ""
        }
        close(slave)
        setNonBlocking(master)
        _ = setpgid(process.processIdentifier, process.processIdentifier)
        kill(process.processIdentifier, SIGWINCH)

        let started = Date()
        var collected = Data()
        var nextStep = 0
        var lastStepAt = started
        var queries = QueryResponder()
        defer {
            terminate(process)
            close(master)
        }

        while Date().timeIntervalSince(started) < timeout {
            if let chunk = readAvailable(master), !chunk.isEmpty {
                collected.append(chunk)
            } else if !process.isRunning {
                if let rest = readAvailable(master) {
                    collected.append(rest)
                }
                break
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }

            let text = decode(collected)
            if abortContaining.contains(where: { containsLoose(text, $0) }) {
                break
            }
            for reply in queries.replies(for: text, colorQuery: replyColorQuery) {
                writeMaster(master, reply)
            }
            if nextStep < steps.count {
                let step = steps[nextStep]
                let elapsed = Date().timeIntervalSince(lastStepAt)
                let matched = step.afterContaining.map { containsLoose(text, $0) } ?? true
                if matched, elapsed >= step.afterSeconds {
                    writeMaster(master, step.write)
                    nextStep += 1
                    lastStepAt = Date()
                }
            } else if stopContaining.contains(where: { containsLoose(text, $0) }) {
                let drainUntil = Date().addingTimeInterval(0.9)
                while Date() < drainUntil {
                    if let extra = readAvailable(master), !extra.isEmpty {
                        collected.append(extra)
                    } else {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
                break
            }
        }
        return stripANSI(decode(collected))
    }

    /// Answers the queries Grok (and similar TUIs) send before they will paint.
    /// A PTY that ignores DA / kitty keyboard / cursor-position hangs on a blank screen.
    struct QueryResponder {
        var cursor = false
        var version = false
        var color = false
        var deviceAttributes = false
        var kittyKeyboard = false
        var trustedDirectory = false

        mutating func replies(for text: String, colorQuery: Bool) -> [Data] {
            var out: [Data] = []
            if !cursor, text.contains("[6n") {
                out.append(Data("\u{1b}[1;1R".utf8))
                cursor = true
            }
            if !version, text.contains("[>0q") {
                out.append(Data("\u{1b}P>|xterm-256color\u{1b}\\".utf8))
                version = true
            }
            if !deviceAttributes, text.contains("\u{1b}[c") || text.contains("\u{1b}[0c") {
                out.append(Data("\u{1b}[?62;1;4;6;9;15;22;29c".utf8))
                deviceAttributes = true
            }
            if !kittyKeyboard, text.contains("[?u") {
                out.append(Data("\u{1b}[?0u".utf8))
                kittyKeyboard = true
            }
            if colorQuery, !color, text.contains("]11;?") {
                out.append(Data("\u{1b}]11;rgb:1e1e/1e1e/1e1e\u{07}".utf8))
                out.append(Data("\u{1b}]10;rgb:ffff/ffff/ffff\u{07}".utf8))
                color = true
            }
            if !trustedDirectory, AgentPTY.containsLoose(text, "Do you trust the contents of this directory") {
                out.append(Data("y\r".utf8))
                trustedDirectory = true
            }
            return out
        }
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// nil = nothing ready yet; empty = EOF.
    private static func readAvailable(_ fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return read(fd, base, raw.count)
        }
        if count > 0 {
            return Data(buffer.prefix(count))
        }
        if count == 0 {
            return Data()
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            return nil
        }
        return Data()
    }

    static func containsLoose(_ text: String, _ needle: String) -> Bool {
        if text.contains(needle) { return true }
        let compact = text.filter { !$0.isWhitespace && !$0.isNewline }
        let target = needle.filter { !$0.isWhitespace && !$0.isNewline }
        return !target.isEmpty && compact.contains(target)
    }

    private static func writeMaster(_ master: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                _ = write(master, base, raw.count)
            }
        }
    }

    private static func terminate(_ process: Process) {
        let pid = process.processIdentifier
        if pid > 0 {
            killpg(pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    static func stripANSI(_ text: String) -> String {
        let patterns = [
            #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#,
            #"\u{1B}\][^\u{07}]*\u{07}"#,
            #"\u{1B}[=>]"#
        ]
        var stripped = text
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                stripped = regex.stringByReplacingMatches(
                    in: stripped,
                    range: NSRange(stripped.startIndex..., in: stripped),
                    withTemplate: ""
                )
            }
        }
        return stripped
    }
}
