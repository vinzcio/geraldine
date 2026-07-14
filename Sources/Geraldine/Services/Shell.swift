import Foundation

enum Shell {
    struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let startedAt: Date
        let finishedAt: Date

        /// Both streams, for human-facing logs and error reporting. Parsers of
        /// machine output (JSON, tables) should read `stdout` — tools like brew
        /// route progress and warnings to stderr.
        var output: String {
            if stderr.isEmpty { return stdout }
            if stdout.isEmpty { return stderr }
            return stdout + "\n" + stderr
        }
    }

    struct AdminResult {
        let ok: Bool
        let output: String
        let startedAt: Date
        let finishedAt: Date
    }

    /// Run a non-interactive command and capture stdout and stderr separately.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> RunResult {
        let startedAt = Date()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return RunResult(status: -1,
                             stdout: "",
                             stderr: (error as NSError).localizedDescription,
                             startedAt: startedAt,
                             finishedAt: Date())
        }
        // Drain stderr alongside stdout so a chatty stream can't fill its pipe
        // and stall the child before stdout reaches EOF.
        var errData = Data()
        let errDrain = DispatchWorkItem { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .utility).async(execute: errDrain)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDrain.wait()
        proc.waitUntilExit()
        return RunResult(status: proc.terminationStatus,
                         stdout: String(data: outData, encoding: .utf8) ?? "",
                         stderr: String(data: errData, encoding: .utf8) ?? "",
                         startedAt: startedAt,
                         finishedAt: Date())
    }

    /// Locate a CLI tool across common locations (Homebrew included).
    static func which(_ tool: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)",
            "/usr/bin/\(tool)", "/bin/\(tool)",
            "/usr/sbin/\(tool)", "/sbin/\(tool)"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        let r = run("/usr/bin/which", [tool])
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.status == 0 && !path.isEmpty) ? path : nil
    }

    /// Run a shell command as administrator (one macOS password prompt) via osascript.
    @discardableResult
    static func runAdmin(_ command: String) -> AdminResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let r = run("/usr/bin/osascript", ["-e", script])
        return AdminResult(ok: r.status == 0,
                           output: r.output,
                           startedAt: r.startedAt,
                           finishedAt: r.finishedAt)
    }
}
