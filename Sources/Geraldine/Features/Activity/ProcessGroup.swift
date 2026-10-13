import Foundation

struct ProcessGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let applicationPath: String?
    let processes: [ProcUsage]

    var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    var memory: Double { processes.reduce(0) { $0 + $1.mem } }
    var representativePID: Int32? { processes.first?.id }

    static func ranked(_ processes: [ProcUsage], byMemory: Bool, query: String = "") -> [Self] {
        let grouped = Dictionary(grouping: processes) { process in
            process.applicationPath.map { "app:\($0)" } ?? "pid:\(process.id)"
        }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return grouped.map { key, members in
            let path = members.first?.applicationPath
            let name = path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? members.first?.name ?? "Process"
            return Self(id: key, name: name, applicationPath: path,
                        processes: members.sorted { $0.id < $1.id })
        }.filter { group in
            let searchable = ([group.name, group.applicationPath ?? ""]
                + group.processes.map { "\($0.name) \($0.id)" }).joined(separator: " ")
            return terms.allSatisfy { searchable.localizedStandardContains($0) }
        }.sorted { lhs, rhs in
            let left = byMemory ? lhs.memory : lhs.cpu
            let right = byMemory ? rhs.memory : rhs.cpu
            return left == right ? lhs.id < rhs.id : left > right
        }
    }
}

enum ActivitySection: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, processes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .processes: "Processes"
        }
    }
}
