import Foundation

struct ProcUsage: Identifiable, Hashable {
    let id: Int32
    let name: String
    let cpu: Double   // %
    let mem: Double   // %
}

enum ProcessSampler {
    /// Top processes by CPU *and* by memory. `ps` sorts on one key at a time, so
    /// a process that is idle but holding gigabytes of RAM never appears in a
    /// purely CPU-ranked head. We take the top `limit` from each ranking and
    /// merge, so a caller re-sorting by either metric sees that metric's true
    /// leaders rather than only the leaders that also rank high on CPU.
    static func sample(limit: Int = 40) -> [ProcUsage] {
        var merged: [Int32: ProcUsage] = [:]
        for sortFlag in ["-r", "-m"] {
            for proc in rows(sortFlag: sortFlag, limit: limit) where merged[proc.id] == nil {
                merged[proc.id] = proc
            }
        }
        return Array(merged.values)
    }

    private static func rows(sortFlag: String, limit: Int) -> [ProcUsage] {
        let r = Shell.run("/bin/ps", ["-A", sortFlag, "-o", "pid=,pcpu=,pmem=,comm="])
        guard r.status == 0 else { return [] }
        var out: [ProcUsage] = []
        for line in r.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let mem = Double(parts[2]) else { continue }
            let name = (String(parts[3]) as NSString).lastPathComponent
            out.append(ProcUsage(id: pid, name: name, cpu: cpu, mem: mem))
            if out.count >= limit { break }
        }
        return out
    }
}
