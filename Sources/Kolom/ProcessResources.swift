import AppKit
import Darwin
import IOKit
import KolomCore

struct ProcessResource: Identifiable {
    let id: String
    let pid: Int32
    let name: String
    let detail: String
    let groupName: String
    let cpu: Double?
    let gpu: Double?
    let memory: Double?
    var cpuHistory: ResourceHistory
    var gpuHistory: ResourceHistory
    var memoryHistory: ResourceHistory
}

/// Read-only counters: libproc for CPU, memory, parents and folders; the IOKit
/// registry for GPU time. No task ports, process termination, packet capture,
/// subprocesses or privileged helper are required.
final class ProcessResourceSampler {
    private var previous: [String: UInt64] = [:]
    private var previousGPU: [String: UInt64] = [:]
    private var histories: [String: (ResourceHistory, ResourceHistory, ResourceHistory)] = [:]
    private var nodeHistories: [String: (ResourceHistory, ResourceHistory, ResourceHistory)] = [:]
    private var sampledAt: TimeInterval?
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return .nan }
        return Double(info.numer) / Double(info.denom)
    }()
    /// macOS's record of which process is responsible for which (what Activity Monitor
    /// groups by). It is not in a public header, so it is looked up at run time; without
    /// it processes are grouped by app bundle and parent alone.
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private let responsibleFor: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    func reset() {
        previous = [:]
        previousGPU = [:]
        histories = [:]
        nodeHistories = [:]
        sampledAt = nil
    }

    struct Result {
        var processes: [ProcessResource]
        var nodes: [ProcessNode]
        var inaccessible: Int
        var gpuMeasured: Bool
    }

    func sample(apps: [ProcessOwnerApp]) -> Result {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = sampledAt.map { now - $0 } ?? 0
        let gpuTimes = GPUStatistics.processTimes()
        var pids = [Int32](repeating: 0, count: 8192)
        let capacity = pids.count * MemoryLayout<Int32>.size
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32(capacity)) }
        guard found > 0 else { return Result(processes: [], nodes: [], inaccessible: 0, gpuMeasured: false) }
        var samples: [ProcessSample] = []
        var counters: [String: UInt64] = [:]
        var gpuCounters: [String: UInt64] = [:]
        var nextHistory: [String: (ResourceHistory, ResourceHistory, ResourceHistory)] = [:]
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
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let hasInfo = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize
            let system = ProcessSample.isSystem(path: path, uid: hasInfo ? info.pbi_uid : 0)
            let responsible = responsibleFor.map { $0(pid) }.flatMap { $0 > 0 ? $0 : nil }
            let total = usage.ri_user_time &+ usage.ri_system_time
            let cpu = processCPUShare(
                previous: previous[id], current: total, elapsed: elapsed,
                cores: ProcessInfo.processInfo.activeProcessorCount, nanosecondsPerTick: nanosecondsPerTick)
            var gpu: Double?
            if let gpuTimes {
                let time = gpuTimes[pid] ?? 0
                gpuCounters[id] = time
                gpu = processGPUShare(previous: previousGPU[id], current: time, elapsed: elapsed)
            }
            let memory = Double(usage.ri_phys_footprint)
            var history = histories[id] ?? (ResourceHistory(), ResourceHistory(), ResourceHistory())
            history.0.append(cpu)
            history.1.append(gpu)
            history.2.append(memory)
            nextHistory[id] = history
            counters[id] = total
            samples.append(
                ProcessSample(
                    id: id, pid: pid, parent: hasInfo ? Int32(info.pbi_ppid) : 0, responsible: responsible,
                    name: name, path: path, directory: system ? nil : workingDirectory(pid), system: system, cpu: cpu,
                    gpu: gpu, memory: memory))
        }
        var nodes = ProcessGrouping.tree(samples, apps: apps, home: home)
        var nextNodes: [String: (ResourceHistory, ResourceHistory, ResourceHistory)] = [:]
        func remember(_ node: inout ProcessNode) {
            var history = nodeHistories[node.id] ?? (ResourceHistory(), ResourceHistory(), ResourceHistory())
            history.0.append(node.cpu)
            history.1.append(node.gpu)
            history.2.append(node.memory)
            nextNodes[node.id] = history
            (node.cpuHistory, node.gpuHistory, node.memoryHistory) = history
            for i in node.children.indices { remember(&node.children[i]) }
        }
        for i in nodes.indices { remember(&nodes[i]) }
        let owners = Dictionary(
            nodes.flatMap { node in leaves(node).map { ($0, node.title) } }, uniquingKeysWith: { a, _ in a })
        let processes = samples.map { sample -> ProcessResource in
            let history = nextHistory[sample.id]!
            return ProcessResource(
                id: sample.id, pid: sample.pid, name: sample.name,
                detail: (["PID \(sample.pid)"]
                    + [sample.directory.map { ProcessGrouping.abbreviate($0, home: home) }].compactMap { $0 })
                    .joined(separator: " · "),
                groupName: owners[sample.pid] ?? sample.name, cpu: sample.cpu, gpu: sample.gpu,
                memory: sample.memory, cpuHistory: history.0, gpuHistory: history.1, memoryHistory: history.2)
        }
        previous = counters
        previousGPU = gpuCounters
        histories = nextHistory
        nodeHistories = nextNodes
        sampledAt = now
        return Result(processes: processes, nodes: nodes, inaccessible: inaccessible, gpuMeasured: gpuTimes != nil)
    }

    private func leaves(_ node: ProcessNode) -> [Int32] {
        node.children.isEmpty ? [node.pid].compactMap { $0 } : node.children.flatMap(leaves)
    }

    private func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }
}

/// GPU readings from the IOKit registry, which publishes them to every user:
/// the accelerator's utilization, and the GPU time of each process using it.
enum GPUStatistics {
    /// "Device Utilization %" of the busiest GPU, 0…1; nil when the Mac reports none.
    static func utilization() -> Double? {
        var best: Double?
        forEachAccelerator { accelerator in
            guard
                let stats = IORegistryEntryCreateCFProperty(accelerator, "PerformanceStatistics" as CFString, nil, 0)?
                    .takeRetainedValue() as? [String: Any],
                let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
            else { return }
            best = max(best ?? 0, min(1, max(0, percent / 100)))
        }
        return best
    }

    /// Accumulated GPU nanoseconds per pid; nil when no accelerator reports them
    /// (Intel and virtual machines).
    static func processTimes() -> [Int32: UInt64]? {
        var times: [Int32: UInt64] = [:]
        var reported = false
        forEachAccelerator { accelerator in
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS else {
                return
            }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard
                    let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, nil, 0)?
                        .takeRetainedValue() as? String, creator.hasPrefix("pid "),
                    let pid = Int32(creator.dropFirst(4).prefix { $0.isNumber }),
                    let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, nil, 0)?
                        .takeRetainedValue() as? [[String: Any]]
                else { continue }
                reported = true
                let time = usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }.reduce(0, &+)
                times[pid, default: 0] &+= time
            }
        }
        return reported ? times : nil
    }

    private static func forEachAccelerator(_ body: (io_registry_entry_t) -> Void) {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators)
            == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            body(accelerator)
            IOObjectRelease(accelerator)
        }
    }
}
