import Foundation
import Darwin

/// Finds Geraldine without launching it. Used only to distinguish "closed" from
/// "running but this build has no control socket", which changes the hint the
/// CLI prints.
public enum ProcessLookup {
    public static func isRunning(named target: String = "Geraldine") -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        let stride = MemoryLayout<kinfo_proc>.stride
        let count = size / stride + 16
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = processes.count * stride
        guard sysctl(&mib, 3, &processes, &size, nil, 0) == 0 else { return false }
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
