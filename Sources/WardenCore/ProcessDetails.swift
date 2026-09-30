import Darwin
import Foundation

/// Reads another process's name, parent, terminal, and working directory. Same-user processes need no permission.
public enum ProcessDetails {
    public static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    public static func parent(of pid: pid_t) -> pid_t? {
        kinfo(pid).map { $0.kp_eproc.e_ppid }
    }

    /// Device name such as `ttys004`, or nil without a controlling terminal.
    public static func tty(of pid: pid_t) -> String? {
        guard let device = kinfo(pid)?.kp_eproc.e_tdev, device != -1,
              let name = devname(device, S_IFCHR) else { return nil }
        return String(cString: name)
    }

    public static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// True while the process exists and, when a name is given, still runs the same executable.
    public static func isAlive(_ pid: pid_t, name expected: String?) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let expected, !expected.isEmpty else { return true }
        return name(of: pid) == expected
    }

    /// The command line a process was started with, its first element being the program. Same-user processes only.
    public static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &maximum, &size, nil, 0) == 0, maximum > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(maximum))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // The argument count, then the executable's path and its padding, then each argument, ending with a zero.
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        var start = index
        while index < size, arguments.count < count {
            if buffer[index] == 0 {
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return arguments
    }

    /// When the process started, in seconds since 1970, computed as psutil computes its create time on macOS.
    public static func startTime(of pid: pid_t) -> Double? {
        guard pid > 0, let start = kinfo(pid)?.kp_proc.p_starttime else { return nil }
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    /// The agent process behind a hook or status line command, skipping the shell Claude Code runs it in.
    public static func agentAncestor(of pid: pid_t) -> pid_t {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env"]
        var current = pid
        for _ in 0..<4 {
            guard shells.contains(name(of: current)), let parent = parent(of: current), parent > 1 else { break }
            current = parent
        }
        return current
    }

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}
