import Foundation

struct ProcUsage: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let cpu: Double   // %
    let mem: Double   // %
}

enum ProcessSampler {
    /// Top processes by CPU via `ps`. Sortable client-side for memory too.
    static func sample(limit: Int = 6) -> [ProcUsage] {
        let r = Shell.run("/bin/ps", ["-A", "-r", "-o", "pcpu=,pmem=,comm="])
        guard r.status == 0 else { return [] }
        var out: [ProcUsage] = []
        for line in r.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let cpu = Double(parts[0]), let mem = Double(parts[1]) else { continue }
            let name = (String(parts[2]) as NSString).lastPathComponent
            out.append(ProcUsage(name: name, cpu: cpu, mem: mem))
            if out.count >= limit { break }
        }
        return out
    }
}
