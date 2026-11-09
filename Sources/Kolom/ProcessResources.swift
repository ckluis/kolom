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
    let network: Double?
    let stoppable: Bool
    var cpuHistory: ResourceHistory
    var gpuHistory: ResourceHistory
    var memoryHistory: ResourceHistory
    var networkHistory: ResourceHistory
}

/// Read-only counters: libproc for CPU, memory, parents and folders; the IOKit
/// registry for GPU time; Apple's `nettop` for network bytes per process (while the
/// dashboard is open). No task ports, packet capture or privileged helper are required.
final class ProcessResourceSampler {
    private var previous: [String: UInt64] = [:]
    private var previousGPU: [String: UInt64] = [:]
    private typealias Histories = (ResourceHistory, ResourceHistory, ResourceHistory, ResourceHistory)
    private static let emptyHistories = (ResourceHistory(), ResourceHistory(), ResourceHistory(), ResourceHistory())
    private var histories: [String: Histories] = [:]
    private var nodeHistories: [String: Histories] = [:]
    private let uid = getuid()
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

    /// `labels` are the names macOS registered processes under; `network` is bytes
    /// per second per pid, nil when unavailable.
    func sample(apps: [ProcessOwnerApp], labels: [Int32: String], network: [Int32: Double]?) -> Result {
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
        var nextHistory: [String: Histories] = [:]
        var inaccessible = 0
        // Other users' processes (WindowServer, root daemons) are closed to libproc;
        // Apple's ps may read them.
        let listed = PSSnapshot.read()
        var terminals: [UInt32: Double?] = [:]
        let wall = Date().timeIntervalSince1970
        for pid in pids.prefix(min(Int(found), pids.count)) where pid > 0 {
            var usage = rusage_info_v2()
            let success =
                withUnsafeMutablePointer(to: &usage) { pointer in
                    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                    }
                } == 0
            guard success else {
                guard let entry = listed?[pid] else {
                    inaccessible += 1
                    continue
                }
                let id = "\(pid):ps:\(entry.path)"
                let cpu = entry.cpu / 100 / Double(ProcessInfo.processInfo.activeProcessorCount)
                var gpu: Double?
                if let gpuTimes {
                    let time = gpuTimes[pid] ?? 0
                    gpuCounters[id] = time
                    gpu = processGPUShare(previous: previousGPU[id], current: time, elapsed: elapsed)
                }
                let traffic = network.map { $0[pid] ?? 0 }
                var history = histories[id] ?? Self.emptyHistories
                history.0.append(cpu)
                history.1.append(gpu)
                history.2.append(entry.memory)
                history.3.append(traffic)
                nextHistory[id] = history
                samples.append(
                    ProcessSample(
                        id: id, pid: pid, parent: entry.parent, responsible: responsibleFor.map { $0(pid) },
                        name: (entry.path as NSString).lastPathComponent, path: entry.path, directory: nil,
                        system: ProcessSample.isSystem(path: entry.path, uid: entry.uid), user: entry.uid == uid,
                        label: labels[pid], cpu: cpu, gpu: gpu, memory: entry.memory, network: traffic))
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
            // A terminal's device is touched whenever anything is typed or printed in it.
            var terminalIdle: Double?
            if hasInfo, !system, info.e_tdev != UInt32.max {
                if let known = terminals[info.e_tdev] {
                    terminalIdle = known
                } else {
                    terminalIdle = Self.terminalIdle(info.e_tdev, now: wall)
                    terminals[info.e_tdev] = terminalIdle
                }
            }
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
            let traffic = network.map { $0[pid] ?? 0 }
            var history = histories[id] ?? Self.emptyHistories
            history.0.append(cpu)
            history.1.append(gpu)
            history.2.append(memory)
            history.3.append(traffic)
            nextHistory[id] = history
            counters[id] = total
            samples.append(
                ProcessSample(
                    id: id, pid: pid, parent: hasInfo ? Int32(info.pbi_ppid) : 0, responsible: responsible,
                    name: name, path: path, directory: system ? nil : workingDirectory(pid), system: system,
                    user: hasInfo && info.pbi_uid == uid, label: labels[pid], cpu: cpu, gpu: gpu, memory: memory,
                    network: traffic, terminalIdle: terminalIdle))
            if let directory = samples.last?.directory, !FileManager.default.fileExists(atPath: directory) {
                samples[samples.count - 1].directoryMissing = true
            }
        }
        var nodes = ProcessGrouping.tree(samples, apps: apps, home: home)
        var nextNodes: [String: Histories] = [:]
        func remember(_ node: inout ProcessNode) {
            var history = nodeHistories[node.id] ?? Self.emptyHistories
            history.0.append(node.cpu)
            history.1.append(node.gpu)
            history.2.append(node.memory)
            history.3.append(node.network)
            nextNodes[node.id] = history
            (node.cpuHistory, node.gpuHistory, node.memoryHistory, node.networkHistory) = history
            for i in node.children.indices { remember(&node.children[i]) }
        }
        for i in nodes.indices { remember(&nodes[i]) }
        let owners = Dictionary(
            nodes.flatMap { node in leaves(node).map { ($0, node.title) } }, uniquingKeysWith: { a, _ in a })
        let processes = samples.map { sample -> ProcessResource in
            let history = nextHistory[sample.id]!
            return ProcessResource(
                id: sample.id, pid: sample.pid, name: ProcessGrouping.displayName(sample),
                detail: (["PID \(sample.pid)"]
                    + [sample.directory.map { ProcessGrouping.abbreviate($0, home: home) }].compactMap { $0 })
                    .joined(separator: " · "),
                groupName: owners[sample.pid] ?? ProcessGrouping.displayName(sample), cpu: sample.cpu,
                gpu: sample.gpu, memory: sample.memory, network: sample.network,
                stoppable: sample.user && !sample.system, cpuHistory: history.0, gpuHistory: history.1,
                memoryHistory: history.2, networkHistory: history.3)
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

    /// Seconds since a terminal device last saw input or output.
    static func terminalIdle(_ device: UInt32, now: Double) -> Double? {
        guard let name = devname(dev_t(bitPattern: device), S_IFCHR) else { return nil }
        var info = stat()
        guard stat("/dev/" + String(cString: name), &info) == 0 else { return nil }
        let touched = Double(max(info.st_mtimespec.tv_sec, info.st_atimespec.tv_sec))
        return max(0, now - touched)
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

/// Bytes per second per process from Apple's `nettop`, which reports every process
/// with network activity (byte counts only, never contents) to a normal user. While
/// the dashboard is open, a short `nettop` run every two seconds measures one second
/// of traffic and exits: output to a pipe arrives only when nettop exits, and nothing
/// is left running if Kolom quits.
final class NetworkSampler {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Kolom.network", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var running: Process?
    private var latest: [Int32: Double]?
    private var measuredAt: TimeInterval?
    private var generation = 0
    static let executable = "/usr/bin/nettop"

    /// The latest per-pid rates; nil until the first measurement, when it is stale,
    /// or when nettop is missing.
    var rates: [Int32: Double]? {
        lock.lock()
        defer { lock.unlock() }
        guard let measuredAt, ProcessInfo.processInfo.systemUptime - measuredAt < 8 else { return nil }
        return latest
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil, FileManager.default.isExecutableFile(atPath: Self.executable) else { return }
        generation += 1
        let current = generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.measure(generation: current) }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        timer?.cancel()
        timer = nil
        running?.terminate()
        running = nil
        latest = nil
        measuredAt = nil
    }

    /// Runs on `queue`, one at a time: two samples one second apart; the second is the delta.
    private func measure(generation current: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Self.executable)
        task.arguments = ["-P", "-d", "-x", "-L", "2", "-s", "1", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        lock.lock()
        guard generation == current else {
            lock.unlock()
            return
        }
        running = task
        lock.unlock()
        do { try task.run() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let rates = NettopParser.rates(String(decoding: data, as: UTF8.self))
        lock.lock()
        defer { lock.unlock() }
        guard generation == current else { return }
        running = nil
        if let rates {
            latest = rates
            measuredAt = ProcessInfo.processInfo.systemUptime
        }
    }

}

/// One `ps` listing, for processes libproc may not read: it reports every process,
/// with CPU as its recent average share of one core and memory as resident size.
enum PSSnapshot {
    static func read() -> [Int32: PSListing.Entry]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", PSListing.format]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return PSListing.parse(String(decoding: data, as: UTF8.self))
    }
}
