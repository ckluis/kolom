import AppKit
import Darwin
import KolomCore

struct ProcessResource: Identifiable {
    let id: String
    let pid: Int32
    let name: String
    let group: String
    let groupName: String
    let cpu: Double?
    let memory: Double?
    var cpuHistory: ResourceHistory
    var memoryHistory: ResourceHistory
}
struct AppResource: Identifiable {
    let id: String
    let name: String
    let cpu: Double?
    let memory: Double?
    let processes: [ProcessResource]
    var cpuHistory: ResourceHistory
    var memoryHistory: ResourceHistory
}

/// Read-only libproc counters. No task ports, process termination, packet capture,
/// private GPU APIs, or privileged helper are required.
final class ProcessResourceSampler {
    private var previous: [String: UInt64] = [:]
    private var histories: [String: (ResourceHistory, ResourceHistory)] = [:]
    private var appHistories: [String: (ResourceHistory, ResourceHistory)] = [:]
    private var sampledAt: TimeInterval?
    private let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return .nan }
        return Double(info.numer) / Double(info.denom)
    }()
    struct AppIdentity {
        let pid: Int32
        let path: String
        let id: String
        let name: String
    }
    func reset() {
        previous = [:]
        histories = [:]
        appHistories = [:]
        sampledAt = nil
    }
    func sample(apps: [AppIdentity]) -> ([ProcessResource], [AppResource], Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = sampledAt.map { now - $0 } ?? 0
        var pids = [Int32](repeating: 0, count: 8192)
        let capacity = pids.count * MemoryLayout<Int32>.size
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32(capacity)) }
        guard found > 0 else { return ([], [], 0) }
        var processes: [ProcessResource] = []
        var counters: [String: UInt64] = [:]
        var nextHistory: [String: (ResourceHistory, ResourceHistory)] = [:]
        var inaccessible = 0
        for pid in pids.prefix(min(Int(found), pids.count)) where pid > 0 {
            var usage = rusage_info_v2()
            let success =
                withUnsafeMutablePointer(to: &usage) { pointer in
                    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                    }
                } == 0
            guard success else {
                inaccessible += 1
                continue
            }
            let id = "\(pid):\(usage.ri_proc_start_abstime)"
            var nameBuffer = [CChar](repeating: 0, count: 1024)
            let nameCount = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = nameCount > 0 ? String(cString: nameBuffer) : "Process \(pid)"
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathCount = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathCount > 0 ? String(cString: pathBuffer) : ""
            let owner =
                apps.first { $0.pid == pid }
                ?? apps.filter { !$0.path.isEmpty && path.hasPrefix($0.path + "/") }.max {
                    $0.path.count < $1.path.count
                }
            let group = owner?.id ?? "process:" + id
            let total = usage.ri_user_time &+ usage.ri_system_time
            let cpu = processCPUShare(
                previous: previous[id], current: total, elapsed: elapsed,
                cores: ProcessInfo.processInfo.activeProcessorCount, nanosecondsPerTick: nanosecondsPerTick)
            let memory = Double(usage.ri_phys_footprint)
            var history = histories[id] ?? (ResourceHistory(), ResourceHistory())
            history.0.append(cpu)
            history.1.append(memory)
            nextHistory[id] = history
            counters[id] = total
            processes.append(
                ProcessResource(
                    id: id, pid: pid, name: name, group: group, groupName: owner?.name ?? name, cpu: cpu,
                    memory: memory, cpuHistory: history.0, memoryHistory: history.1))
        }
        var grouped: [AppResource] = []
        var nextApps: [String: (ResourceHistory, ResourceHistory)] = [:]
        for (id, children) in Dictionary(grouping: processes, by: { $0.group }) {
            let cpu = children.allSatisfy { $0.cpu != nil } ? children.compactMap(\.cpu).reduce(0, +) : nil
            let memory = children.compactMap(\.memory).reduce(0, +)
            var history = appHistories[id] ?? (ResourceHistory(), ResourceHistory())
            history.0.append(cpu)
            history.1.append(memory)
            nextApps[id] = history
            grouped.append(
                AppResource(
                    id: id, name: children.first!.groupName, cpu: cpu, memory: memory,
                    processes: children.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }, cpuHistory: history.0,
                    memoryHistory: history.1))
        }
        previous = counters
        histories = nextHistory
        appHistories = nextApps
        sampledAt = now
        return (processes, grouped, inaccessible)
    }
}
