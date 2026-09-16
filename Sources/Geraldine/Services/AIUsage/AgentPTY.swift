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
        var env = ProcessInfo.processInfo.environment
        env["COLUMNS"] = "120"
        env["LINES"] = "40"
        environment.forEach { env[$0.key] = $0.value }
        process.environment = env
        do { try process.run() } catch {
            close(slave)
            close(master)
            return ""
        }
        close(slave)
        _ = setpgid(process.processIdentifier, process.processIdentifier)
        kill(process.processIdentifier, SIGWINCH)

        let started = Date()
        var collected = Data()
        var nextStep = 0
        var lastStepAt = started
        var repliedColor = false
        var repliedCursor = false
        var repliedVersion = false
        let handle = FileHandle(fileDescriptor: master, closeOnDealloc: false)
        defer {
            terminate(process)
            close(master)
        }

        while Date().timeIntervalSince(started) < timeout {
            let chunk = handle.availableData
            if !chunk.isEmpty {
                collected.append(chunk)
            } else if !process.isRunning {
                let rest = handle.availableData
                collected.append(rest)
                break
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }

            let text = decode(collected)
            if !repliedCursor, text.contains("[6n") {
                writeMaster(master, Data("\u{1b}[1;1R".utf8))
                repliedCursor = true
            }
            if !repliedVersion, text.contains("[>0q") {
                writeMaster(master, Data("\u{1b}P>|xterm-256color\u{1b}\\".utf8))
                repliedVersion = true
            }
            if replyColorQuery, !repliedColor, text.contains("]11;?") {
                writeMaster(master, Data("\u{1b}]11;rgb:1e1e/1e1e/1e1e\u{07}".utf8))
                writeMaster(master, Data("\u{1b}]10;rgb:ffff/ffff/ffff\u{07}".utf8))
                repliedColor = true
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
                Thread.sleep(forTimeInterval: 0.7)
                collected.append(handle.availableData)
                break
            }
        }
        return stripANSI(decode(collected))
    }

    private static func containsLoose(_ text: String, _ needle: String) -> Bool {
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
