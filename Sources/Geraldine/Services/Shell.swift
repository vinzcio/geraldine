import Foundation

enum Shell {
    struct RunResult {
        let status: Int32
        let output: String
        let startedAt: Date
        let finishedAt: Date
    }

    struct AdminResult {
        let ok: Bool
        let output: String
        let startedAt: Date
        let finishedAt: Date
    }

    /// Run a non-interactive command and capture combined output.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> RunResult {
        let startedAt = Date()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return RunResult(status: -1,
                             output: (error as NSError).localizedDescription,
                             startedAt: startedAt,
                             finishedAt: Date())
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return RunResult(status: proc.terminationStatus,
                         output: String(data: data, encoding: .utf8) ?? "",
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
        let path = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
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
