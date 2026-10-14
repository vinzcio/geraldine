import Darwin
import Foundation

/// Drive an official agent TUI just long enough to run a local slash command.
/// The child owns authentication; Geraldine only types the command and reads
/// the screen. The TUI runs in its own session with the PTY as its controlling
/// terminal: if Geraldine quits or crashes mid-capture, closing the master
/// hangs that terminal up and the TUI exits instead of running on unowned.
enum AgentPTY {
    struct Step: Sendable {
        var afterContaining: String?
        var afterSeconds: TimeInterval
        var write: Data
    }

    /// A screen that may or may not appear, such as an approval dialog. Answered
    /// once, and only while its text is on screen.
    struct PromptReply: Sendable {
        var containing: String
        var write: Data
    }

    /// Screens are matched on text with the escape sequences removed, so styling
    /// such as a reverse-video fake cursor inside a placeholder cannot hide it.
    /// After each step or prompt reply, the next trigger must arrive in new
    /// output: a keystroke never lands on a dialog that opened in between.
    static func capture(
        executable: URL,
        arguments: [String],
        homeDirectory: URL,
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        replyColorQuery: Bool = false,
        steps: [Step],
        promptReplies: [PromptReply] = [],
        stopContaining: [String],
        abortContaining: [String] = [],
        timeout: TimeInterval
    ) -> String {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let name = ptsname(master), let slaveName = String(cString: name, encoding: .utf8) else {
            if master >= 0 { close(master) }
            return ""
        }
        // The window size only sticks once the slave is open; set before that,
        // the child's first open resets it and the TUI lays out one column
        // wide. O_NOCTTY keeps this descriptor from claiming the terminal, and
        // it closes once the child has opened its own.
        let sizer = open(slaveName, O_RDWR | O_NOCTTY)
        guard sizer >= 0 else {
            close(master)
            return ""
        }
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(sizer, TIOCSWINSZ, &size)
        _ = ioctl(master, TIOCSWINSZ, &size)

        var env = AgentCLI.environment(homeDirectory: homeDirectory)
        env.removeValue(forKey: "NO_COLOR")
        env.removeValue(forKey: "CI")
        env["COLUMNS"] = "120"
        env["LINES"] = "40"
        env["TERM"] = env["TERM"].flatMap { $0.isEmpty ? nil : $0 } ?? "xterm-256color"
        env["COLORTERM"] = env["COLORTERM"] ?? "truecolor"
        environment.forEach { env[$0.key] = $0.value }
        let spawned = spawnSession(executable: executable, arguments: arguments, terminal: slaveName,
                                   directory: workingDirectory ?? homeDirectory, environment: env)
        close(sizer)
        guard let pid = spawned else {
            close(master)
            return ""
        }
        setNonBlocking(master)
        kill(pid, SIGWINCH)

        let started = Date()
        var collected = Data()
        var raw = ""
        var plain = ""
        // Bytes before `fresh` were on screen before the last keystroke.
        var fresh = 0
        var freshPlain = ""
        var nextStep = 0
        var lastStepAt = started
        var answered = Set<Int>()
        var queries = QueryResponder()
        var reaped = false
        defer { finish(pid: pid, master: master, reaped: reaped) }

        func keystroke(_ data: Data) {
            writeMaster(master, data)
            lastStepAt = Date()
            fresh = collected.count
            freshPlain = ""
        }

        while Date().timeIntervalSince(started) < timeout {
            if let chunk = readAvailable(master), !chunk.isEmpty {
                collected.append(chunk)
                raw = decode(collected)
                plain = stripANSI(raw)
                freshPlain = fresh == 0 ? plain : stripANSI(decode(collected.suffix(from: fresh)))
            } else if !isRunning(pid, reaped: &reaped) {
                if let rest = readAvailable(master) {
                    collected.append(rest)
                }
                break
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }

            if abortContaining.contains(where: { containsLoose(plain, $0) }) {
                break
            }
            for reply in queries.replies(for: raw, colorQuery: replyColorQuery) {
                writeMaster(master, reply)
            }
            if let index = promptReplies.indices.first(where: {
                !answered.contains($0) && containsLoose(freshPlain, promptReplies[$0].containing)
            }) {
                answered.insert(index)
                keystroke(promptReplies[index].write)
                continue
            }
            if nextStep < steps.count {
                let step = steps[nextStep]
                let elapsed = Date().timeIntervalSince(lastStepAt)
                let matched = step.afterContaining.map { containsLoose(freshPlain, $0) } ?? true
                if matched, elapsed >= step.afterSeconds {
                    keystroke(step.write)
                    nextStep += 1
                }
            } else if stopContaining.contains(where: { containsLoose(freshPlain, $0) }) {
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

    /// posix_spawn with POSIX_SPAWN_SETSID. The child opens the slave itself,
    /// which makes it the new session's controlling terminal, so the child gets
    /// SIGHUP when the master closes, including when Geraldine exits. Every
    /// other descriptor is closed in the child, so it never holds the master.
    private static func spawnSession(executable: URL, arguments: [String], terminal: String,
                                     directory: URL, environment: [String: String]) -> pid_t? {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, terminal, O_RDWR, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO) == 0 else { return nil }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp) == 0 else { return nil }
        return pid
    }

    /// Reaps the child once it has exited; false from then on.
    private static func isRunning(_ pid: pid_t, reaped: inout Bool) -> Bool {
        guard !reaped else { return false }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result < 0 && errno == ECHILD) {
            reaped = true
            return false
        }
        return true
    }

    /// Kill the session, then close the master before reaping: a dying session
    /// leader can block in exit while its terminal output drains, and nothing
    /// reads the master once the capture is over.
    private static func finish(pid: pid_t, master: Int32, reaped: Bool) {
        if !reaped {
            killpg(pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        close(master)
        guard !reaped else { return }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
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

    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    static func stripANSI(_ text: String) -> String {
        let replacements = [
            // Cursor-positioned redraws contain no newlines. Separate their
            // text so a reset date cannot absorb the next row's session usage.
            (#"\x{1B}\[[0-9;]*[Hf]"#, "\n"),
            // Any CSI: parameter bytes 0-?, which includes private `<=>`
            // forms such as the kitty keyboard `ESC[>1u`.
            (#"\x{1B}\[[0-?]*[ -/]*[@-~]"#, ""),
            (#"\x{1B}\][^\x{07}]*\x{07}"#, ""),
            (#"\x{1B}[=>]"#, "")
        ]
        var stripped = text
        for (pattern, replacement) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                stripped = regex.stringByReplacingMatches(
                    in: stripped,
                    range: NSRange(stripped.startIndex..., in: stripped),
                    withTemplate: replacement
                )
            }
        }
        return stripped
    }
}
