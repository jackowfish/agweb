import Darwin
import Foundation

@_silgen_name("responsibility_get_pid_responsible_for_pid") private func responsiblePID(_ pid: pid_t) -> pid_t

/// CPU and memory as Activity Monitor shows them: CPU as a share of one core, memory as the physical footprint.
struct Usage: Equatable {
    /// Nil on a process's first sample: CPU needs two.
    var cpu: Double?
    var memory: UInt64

    var label: String {
        let memory = ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)
        return cpu.map { String(format: "CPU %.1f%% · %@", $0, memory) } ?? memory
    }
}

/// Samples agweb and every process macOS counts as its own: one page process per tab or so, the GPU and networking
/// processes. One proc_pid_rusage call per process, every 5 s, only while the dashboard shows the numbers.
@MainActor
final class UsageSampler {
    private var previous: [pid_t: (cpu: UInt64, at: UInt64)] = [:]
    /// Whether each running process is agweb's: asking costs a call per process on the Mac, and the answer holds for a
    /// process's life. Pruned to the running pids each time.
    private var ours: [pid_t: Bool] = [:]
    private var sampledAt = Date.distantPast

    /// Each process's usage since the last call, keyed by pid, with its name; no CPU on a process's first sample.
    func sample() -> [pid_t: (name: String, usage: Usage)] {
        let me = getpid()
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var result: [pid_t: (name: String, usage: Usage)] = [:]
        var seen: [pid_t: (cpu: UInt64, at: UInt64)] = [:]
        let now = mach_absolute_time()
        let running = pids.prefix(max(0, count)).filter { $0 > 0 }
        // A pid freed and reused since the last look would keep the old answer.
        // And CPU since the last look would average over the whole gap.
        if Date().timeIntervalSince(sampledAt) > 30 { ours = [:]; previous = [:] }
        sampledAt = Date()
        var known: [pid_t: Bool] = [:]
        for pid in running { known[pid] = ours[pid] ?? (pid == me || responsiblePID(pid) == me) }
        ours = known
        for pid in running where known[pid] == true {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            // In mach_absolute_time's units on Apple silicon and nanoseconds on Intel, like the clock, so the ratio holds.
            let cpu = info.ri_user_time + info.ri_system_time
            seen[pid] = (cpu, now)
            var share: Double?
            if let last = previous[pid], now > last.at, cpu >= last.cpu {
                share = Double(cpu - last.cpu) / Double(now - last.at) * 100
            }
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            result[pid] = (String(cString: name), Usage(cpu: share, memory: info.ri_phys_footprint))
        }
        previous = seen
        return result
    }
}
