import Foundation
import Darwin

/// Finds Geraldine without launching it. Used only to distinguish "closed" from
/// "running but this build has no control socket", which changes the hint the
/// CLI prints.
public enum ProcessLookup {
    public static func isRunning(named target: String = "Geraldine") -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(geteuid())]
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes: [kinfo_proc]
        var size = 0
        while true {
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return false }
            processes = [kinfo_proc](repeating: kinfo_proc(), count: (size + stride - 1) / stride)
            size = processes.count * stride
            if sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 { break }
            // Process creation can grow the table between the two calls.
            guard errno == ENOMEM else { return false }
        }
        let actual = size / stride
        for index in 0..<actual {
            let name = withUnsafePointer(to: processes[index].kp_proc.p_comm) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == target { return true }
        }
        return false
    }
}
